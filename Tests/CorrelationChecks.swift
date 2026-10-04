import Foundation

#if DEBUG
#endif

enum CorrelationChecks {
    static func run() throws {
        let rate = 48_000.0
        let chirp = Chirp.make(sampleRate: rate)
        let offset = 8_000
        var recording = [Float](repeating: 0, count: offset + chirp.count + 2_000)
        for (index, sample) in chirp.enumerated() {
            recording[offset + index] = sample
        }
        let located = try Chirp.locate(template: chirp, in: recording)
        let error = abs(located.sample - Double(offset))
        if error > 1 {
            throw CheckFailure("expected the chirp at sample \(offset), found \(located.sample)")
        }

        var noisy = recording
        for index in noisy.indices {
            noisy[index] += Float.random(in: -0.02...0.02)
        }
        let noisyLocated = try Chirp.locate(template: chirp, in: noisy)
        if abs(noisyLocated.sample - Double(offset)) > 2 {
            throw CheckFailure("noisy chirp landed at \(noisyLocated.sample)")
        }
        print("correlation ok (error \(error) samples, quality \(located.quality))")
        try ToneChecks.run()
    }
}

enum ToneChecks {
    static func run() throws {
        let rate = 48_000.0
        let pulse = mix(rate: rate, lows: 1, mids: 0.25, highs: 0.08)
        let sony = mix(rate: rate, lows: 0.08, mids: 0.25, highs: 1)
        let pulseShape = ToneSplit.shape(samples: pulse, sampleRate: rate)
        let sonyShape = ToneSplit.shape(samples: sony, sampleRate: rate)
        let cuts = ToneSplit.cuts(for: [pulseShape, sonyShape])
        if cuts[1].lowDB >= -1 {
            throw CheckFailure("expected the weaker low end to be turned down, sony low cut was \(cuts[1].lowDB)")
        }
        if cuts[0].highDB >= -1 {
            throw CheckFailure("expected the weaker high end to be turned down, pulse high cut was \(cuts[0].highDB)")
        }
        if cuts[0].lowDB != 0 || cuts[1].highDB != 0 {
            throw CheckFailure("the stronger band should stay untouched")
        }
        var eq = Biquad()
        var sawNan = false
        for _ in 0..<1_000 {
            let y = eq.process(0.2)
            if y.isNaN { sawNan = true }
        }
        if sawNan || abs(eq.process(0.2) - 0.2) > 0.001 {
            throw CheckFailure("a flat filter changed the signal")
        }
        print("tone split ok (sony lows \(cuts[1].lowDB) dB, pulse highs \(cuts[0].highDB) dB)")
    }

    private static func mix(rate: Double, lows: Float, mids: Float, highs: Float) -> [Float] {
        let count = Int(rate)
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let t = Double(index) / rate
            samples[index] = lows * Float(sin(2 * Double.pi * 140 * t))
                + mids * Float(sin(2 * Double.pi * 1_000 * t))
                + highs * Float(sin(2 * Double.pi * 5_000 * t))
        }
        return samples
    }
}

struct CheckFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

@main
enum TestMain {
    static func main() throws {
        try CorrelationChecks.run()
    }
}
