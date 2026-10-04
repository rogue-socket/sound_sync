import Foundation
import Synchronization

/// One writer, many readers. Samples are interleaved stereo at `sampleRate`.
final class SharedClock: @unchecked Sendable {
    static let capacityFrames = 192_000 * 6

    let storage: UnsafeMutablePointer<Float>
    private let writeFrame = Atomic<Int64>(0)
    private let lastLoudFrame = Atomic<Int64>(-1)
    private var localWrite: Int64 = 0
    private(set) var sampleRate: Double = 48_000

    init() {
        storage = .allocate(capacity: Self.capacityFrames * 2)
        storage.initialize(repeating: 0, count: Self.capacityFrames * 2)
    }

    deinit {
        storage.deallocate()
    }

    func setSampleRate(_ rate: Double) {
        sampleRate = rate
    }

    var publishedFrame: Int64 {
        writeFrame.load(ordering: .acquiring)
    }

    func append(_ samples: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        var peak: Float = 0
        var remaining = frames
        var source = samples
        let total = frames * 2
        for index in 0..<total {
            peak = max(peak, abs(samples[index]))
        }
        while remaining > 0 {
            let index = Int(localWrite % Int64(Self.capacityFrames))
            let space = Self.capacityFrames - index
            let chunk = min(space, remaining)
            storage.advanced(by: index * 2).update(from: source, count: chunk * 2)
            localWrite += Int64(chunk)
            source = source.advanced(by: chunk * 2)
            remaining -= chunk
        }
        if peak > 0.01 {
            lastLoudFrame.store(localWrite, ordering: .releasing)
        }
        writeFrame.store(localWrite, ordering: .releasing)
    }

    func silenceSeconds() -> Double {
        let loud = lastLoudFrame.load(ordering: .acquiring)
        guard loud >= 0 else { return 0 }
        let gap = publishedFrame - loud
        guard gap > 0 else { return 0 }
        return Double(gap) / max(sampleRate, 1)
    }
}

/// Pulls the shared clock into one speaker, keeping a steady delay.
final class SpeakerReader: @unchecked Sendable {
    private let clock: SharedClock
    private var readFrame: Double = 0
    private var primed = false
    private let delayBits = Atomic<UInt64>(0)
    private let gainBits = Atomic<UInt32>(Float(1).bitPattern)
    private let prerollSeconds = 0.15

    init(clock: SharedClock) {
        self.clock = clock
    }

    func setDelay(_ seconds: Double) {
        let previous = delay
        delayBits.store(seconds.bitPattern, ordering: .releasing)
        if primed {
            readFrame -= (seconds - previous) * clock.sampleRate
        }
    }

    func setGain(_ gain: Float) {
        gainBits.store(gain.bitPattern, ordering: .relaxed)
    }

    var delay: Double {
        Double(bitPattern: delayBits.load(ordering: .acquiring))
    }

    var gain: Float {
        Float(bitPattern: gainBits.load(ordering: .relaxed))
    }

    func pull(frames: Int, outputRate: Double, into destination: UnsafeMutablePointer<Float>) {
        guard frames > 0, clock.sampleRate > 0, outputRate > 0 else {
            destination.update(repeating: 0, count: frames * 2)
            return
        }

        let published = Double(clock.publishedFrame)
        let delayFrames = delay * clock.sampleRate
        let targetGap = prerollSeconds * clock.sampleRate + delayFrames

        if !primed {
            guard published > targetGap + Double(frames) else {
                destination.update(repeating: 0, count: frames * 2)
                return
            }
            readFrame = published - targetGap
            primed = true
        }

        let gap = published - readFrame
        if gap < Double(frames) * clock.sampleRate / outputRate {
            primed = false
            destination.update(repeating: 0, count: frames * 2)
            return
        }

        let error = gap - targetGap
        let correction = max(-0.01, min(0.01, error / (clock.sampleRate * 2)))
        let step = (clock.sampleRate / outputRate) * (1 + correction)
        let amplitude = gain
        let capacity = Double(SharedClock.capacityFrames)

        for frame in 0..<frames {
            let position = readFrame
            let index = Int(position.rounded(.down))
            let fraction = Float(position - Double(index))
            let left = sample(channel: 0, frame: index)
            let right = sample(channel: 1, frame: index)
            let nextLeft = sample(channel: 0, frame: index + 1)
            let nextRight = sample(channel: 1, frame: index + 1)
            destination[frame * 2] = (left + (nextLeft - left) * fraction) * amplitude
            destination[frame * 2 + 1] = (right + (nextRight - right) * fraction) * amplitude
            readFrame += step
            if published - readFrame > capacity - 1024 {
                readFrame = published - targetGap
            }
        }
    }

    private func sample(channel: Int, frame: Int) -> Float {
        let wrapped = frame % SharedClock.capacityFrames
        let index = wrapped < 0 ? wrapped + SharedClock.capacityFrames : wrapped
        return clock.storage[index * 2 + channel]
    }
}
