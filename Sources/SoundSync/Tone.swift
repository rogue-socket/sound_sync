import Accelerate
import Foundation

struct BandLevel {
    var low: Float
    var mid: Float
    var high: Float
}

struct BandCut {
    var lowDB: Float
    var midDB: Float
    var highDB: Float

    static let flat = BandCut(lowDB: 0, midDB: 0, highDB: 0)

    var isFlat: Bool {
        abs(lowDB) < 0.4 && abs(midDB) < 0.4 && abs(highDB) < 0.4
    }
}

enum ToneSplit {
    /// Relative tone, with overall loudness removed. A higher number means that speaker is stronger in that band than in the rest of its own sound.
    static func shape(samples: [Float], sampleRate: Double) -> BandLevel {
        let raw = energies(samples: samples, sampleRate: sampleRate)
        let mean = (raw.low + raw.mid + raw.high) / 3
        return BandLevel(low: raw.low - mean, mid: raw.mid - mean, high: raw.high - mean)
    }

    /// Turn down a band on the speaker that is weaker there. Never boost, so a small driver is not asked to play what it cannot.
    static func assignment(pulse: BandLevel, sony: BandLevel) -> (pulse: BandCut, sony: BandCut) {
        func cut(_ stronger: Float, _ weaker: Float) -> Float {
            let gap = stronger - weaker
            guard gap > 3 else { return 0 }
            return max(-8, -0.5 * (gap - 3))
        }
        return (
            BandCut(
                lowDB: cut(sony.low, pulse.low),
                midDB: cut(sony.mid, pulse.mid),
                highDB: cut(sony.high, pulse.high)
            ),
            BandCut(
                lowDB: cut(pulse.low, sony.low),
                midDB: cut(pulse.mid, sony.mid),
                highDB: cut(pulse.high, sony.high)
            )
        )
    }

    static func summary(pulse: BandCut, sony: BandCut) -> String {
        var parts: [String] = []
        func mention(_ label: String, pulseCut: Float, sonyCut: Float) {
            if sonyCut < pulseCut - 0.4 {
                parts.append("The Pulse 4 is carrying more of the \(label).")
            } else if pulseCut < sonyCut - 0.4 {
                parts.append("The SRS-XB13 is carrying more of the \(label).")
            }
        }
        mention("lows", pulseCut: pulse.lowDB, sonyCut: sony.lowDB)
        mention("mids", pulseCut: pulse.midDB, sonyCut: sony.midDB)
        mention("highs", pulseCut: pulse.highDB, sonyCut: sony.highDB)
        if parts.isEmpty {
            return "Their tone is close, so both play the full range."
        }
        return parts.joined(separator: " ")
    }

    private static func energies(samples: [Float], sampleRate: Double) -> BandLevel {
        guard samples.count >= 32, sampleRate > 1 else {
            return BandLevel(low: -80, mid: -80, high: -80)
        }
        let count = 1 << Int(ceil(log2(Double(samples.count))))
        var real = [Float](repeating: 0, count: count)
        var imag = [Float](repeating: 0, count: count)
        let used = min(samples.count, count)
        for index in 0..<used {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(max(used - 1, 1)))
            real[index] = samples[index] * Float(window)
        }
        var outReal = [Float](repeating: 0, count: count)
        var outImag = [Float](repeating: 0, count: count)
        if let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(count), .FORWARD) {
            vDSP_DFT_Execute(setup, &real, &imag, &outReal, &outImag)
            vDSP_DFT_DestroySetup(setup)
        }

        func average(from lowHz: Double, to highHz: Double) -> Float {
            let binHz = sampleRate / Double(count)
            let start = max(Int(lowHz / binHz), 1)
            var end = min(Int(highHz / binHz), count / 2 - 1)
            if end <= start { end = start + 1 }
            var sum: Float = 0
            var bins = 0
            for bin in start...end {
                let mag = sqrt(outReal[bin] * outReal[bin] + outImag[bin] * outImag[bin])
                sum += mag
                bins += 1
            }
            let mean = sum / Float(max(bins, 1))
            return 20 * log10(max(mean, 1e-7))
        }

        return BandLevel(
            low: average(from: 90, to: 250),
            mid: average(from: 250, to: 2_000),
            high: average(from: 2_000, to: 7_500)
        )
    }
}

struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    static func lowShelf(sampleRate: Double, frequency: Double, gainDB: Float) -> Biquad {
        shelf(sampleRate: sampleRate, frequency: frequency, gainDB: gainDB, high: false)
    }

    static func highShelf(sampleRate: Double, frequency: Double, gainDB: Float) -> Biquad {
        shelf(sampleRate: sampleRate, frequency: frequency, gainDB: gainDB, high: true)
    }

    static func peak(sampleRate: Double, frequency: Double, gainDB: Float, q: Double) -> Biquad {
        if abs(gainDB) < 0.4 { return Biquad() }
        let a = pow(10, Double(gainDB) / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosw = cos(w0)
        let b0 = 1 + alpha * a
        let b1 = -2 * cosw
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw
        let a2 = 1 - alpha / a
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    private static func shelf(sampleRate: Double, frequency: Double, gainDB: Float, high: Bool) -> Biquad {
        if abs(gainDB) < 0.4 { return Biquad() }
        let a = pow(10, Double(gainDB) / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / 2 * sqrt((a + 1 / a) * (1 / 1 - 1) + 2)
        let sqrtA = sqrt(a)
        let b0: Double
        let b1: Double
        let b2: Double
        let a0: Double
        let a1: Double
        let a2: Double
        if high {
            b0 = a * ((a + 1) + (a - 1) * cosw + 2 * sqrtA * alpha)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosw)
            b2 = a * ((a + 1) + (a - 1) * cosw - 2 * sqrtA * alpha)
            a0 = (a + 1) - (a - 1) * cosw + 2 * sqrtA * alpha
            a1 = 2 * ((a - 1) - (a + 1) * cosw)
            a2 = (a + 1) - (a - 1) * cosw - 2 * sqrtA * alpha
        } else {
            b0 = a * ((a + 1) - (a - 1) * cosw + 2 * sqrtA * alpha)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
            b2 = a * ((a + 1) - (a - 1) * cosw - 2 * sqrtA * alpha)
            a0 = (a + 1) + (a - 1) * cosw + 2 * sqrtA * alpha
            a1 = -2 * ((a - 1) + (a + 1) * cosw)
            a2 = (a + 1) + (a - 1) * cosw - 2 * sqrtA * alpha
        }
        return normalized(b0: b0, b1: b1, b2: b2, a0: a0, a1: a1, a2: a2)
    }

    private static func normalized(b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double) -> Biquad {
        Biquad(
            b0: Float(b0 / a0),
            b1: Float(b1 / a0),
            b2: Float(b2 / a0),
            a1: Float(a1 / a0),
            a2: Float(a2 / a0)
        )
    }
}

final class StereoEQ {
    private var lowL = Biquad()
    private var lowR = Biquad()
    private var midL = Biquad()
    private var midR = Biquad()
    private var highL = Biquad()
    private var highR = Biquad()

    func update(sampleRate: Double, cut: BandCut) {
        lowL = Biquad.lowShelf(sampleRate: sampleRate, frequency: 160, gainDB: cut.lowDB)
        lowR = lowL
        midL = Biquad.peak(sampleRate: sampleRate, frequency: 1_000, gainDB: cut.midDB, q: 0.7)
        midR = midL
        highL = Biquad.highShelf(sampleRate: sampleRate, frequency: 4_000, gainDB: cut.highDB)
        highR = highL
    }

    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            var left = samples[frame * 2]
            var right = samples[frame * 2 + 1]
            left = lowL.process(left)
            right = lowR.process(right)
            left = midL.process(left)
            right = midR.process(right)
            left = highL.process(left)
            right = highR.process(right)
            samples[frame * 2] = left
            samples[frame * 2 + 1] = right
        }
    }
}
