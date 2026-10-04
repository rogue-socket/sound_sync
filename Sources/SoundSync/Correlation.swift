import Accelerate
import Foundation

enum Chirp {
    static let duration = 0.7
    static let startFrequency = 80.0
    static let endFrequency = 8_000.0

    static func make(sampleRate: Double, duration: Double = Chirp.duration) -> [Float] {
        let count = max(Int(sampleRate * duration), 8)
        let k = log(endFrequency / startFrequency) / Double(count)
        var samples = [Float](repeating: 0, count: count)
        var phase = 0.0
        for index in 0..<count {
            let frequency = startFrequency * exp(k * Double(index))
            phase += 2 * Double.pi * frequency / sampleRate
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
            samples[index] = Float(sin(phase) * window * 0.9)
        }
        return samples
    }

    /// Returns the fractional sample index where `template` best matches `recording`.
    static func locate(template: [Float], in recording: [Float]) throws -> LocatedChirp {
        guard template.count >= 8, recording.count > template.count + 8 else {
            throw ChirpError.tooShort
        }

        let resultCount = recording.count - template.count + 1
        var correlation = [Float](repeating: 0, count: resultCount)
        recording.withUnsafeBufferPointer { recordingBuffer in
            template.withUnsafeBufferPointer { templateBuffer in
                correlation.withUnsafeMutableBufferPointer { correlationBuffer in
                    guard let recordingBase = recordingBuffer.baseAddress,
                          let templateBase = templateBuffer.baseAddress,
                          let correlationBase = correlationBuffer.baseAddress else {
                        return
                    }
                    vDSP_conv(
                        recordingBase,
                        1,
                        templateBase,
                        1,
                        correlationBase,
                        1,
                        vDSP_Length(resultCount),
                        vDSP_Length(template.count)
                    )
                }
            }
        }

        var templateEnergy: Float = 0
        vDSP_svesq(template, 1, &templateEnergy, vDSP_Length(template.count))
        guard templateEnergy > 0 else { throw ChirpError.tooShort }

        var peakIndex = 0
        var peak: Float = -.greatestFiniteMagnitude
        for (index, value) in correlation.enumerated() where value > peak {
            peak = value
            peakIndex = index
        }

        var meanMagnitude: Float = 0
        vDSP_meamgv(correlation, 1, &meanMagnitude, vDSP_Length(resultCount))
        let quality = peak / templateEnergy
        guard quality > 0.02, peak > meanMagnitude * 6 else {
            throw ChirpError.notHeard(quality: quality)
        }

        var fractional = Double(peakIndex)
        if peakIndex > 0 && peakIndex < resultCount - 1 {
            let left = correlation[peakIndex - 1]
            let center = correlation[peakIndex]
            let right = correlation[peakIndex + 1]
            let denominator = left - 2 * center + right
            if abs(denominator) > 1e-8 {
                fractional += Double(0.5 * (left - right) / denominator)
            }
        }
        return LocatedChirp(sample: fractional, quality: quality)
    }
}

struct LocatedChirp {
    var sample: Double
    var quality: Float
}

enum ChirpError: Error, CustomStringConvertible {
    case tooShort
    case notHeard(quality: Float)

    var description: String {
        switch self {
        case .tooShort:
            return "The recording was too short to measure."
        case .notHeard(let quality):
            return String(format: "The chirp was too quiet to measure (match %.2f). Move the speaker closer and try again.", quality)
        }
    }
}
