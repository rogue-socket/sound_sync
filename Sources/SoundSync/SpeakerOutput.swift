import CoreAudio
import Foundation
import Synchronization

final class SpeakerOutput {
    let device: AudioDeviceInfo
    let reader: SpeakerReader
    private(set) var sampleRate: Double = 48_000
    private var format = AudioStreamBasicDescription()
    private var ioProc: AudioDeviceIOProcID?
    private var renderScratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 16_384

    private let mode = Atomic<Int>(SpeakerMode.play.rawValue)
    private var chirp: UnsafeMutablePointer<Float>?
    private var chirpCount = 0
    private let chirpCursor = Atomic<Int>(0)
    private let chirpHost = Atomic<UInt64>(0)
    private let eq = StereoEQ()

    init(device: AudioDeviceInfo, clock: SharedClock) {
        self.device = device
        reader = SpeakerReader(clock: clock)
        renderScratch = .allocate(capacity: scratchFrames * 2)
    }

    deinit {
        chirp?.deallocate()
        renderScratch.deallocate()
    }

    func start() throws {
        format = try AudioDevices.streamFormat(device.id, scope: kAudioObjectPropertyScopeOutput)
        sampleRate = format.mSampleRate > 0 ? format.mSampleRate : try AudioDevices.nominalSampleRate(device.id)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var proc: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcID(device.id, Self.ioProc, refcon, &proc).check("Create output for \(device.name)")
        ioProc = proc
        try AudioDeviceStart(device.id, proc).check("Start output for \(device.name)")
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(device.id, ioProc)
            AudioDeviceDestroyIOProcID(device.id, ioProc)
        }
        ioProc = nil
    }

    func playChirp(_ samples: [Float]) {
        chirp?.deallocate()
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
        buffer.initialize(from: samples, count: samples.count)
        chirp = buffer
        chirpCount = samples.count
        chirpCursor.store(0, ordering: .releasing)
        chirpHost.store(0, ordering: .releasing)
        mode.store(SpeakerMode.chirp.rawValue, ordering: .releasing)
    }

    func silence() {
        mode.store(SpeakerMode.silence.rawValue, ordering: .releasing)
    }

    func resume() {
        mode.store(SpeakerMode.play.rawValue, ordering: .releasing)
    }

    func setTone(_ cut: BandCut) {
        eq.update(sampleRate: sampleRate, cut: cut)
    }

    func takeChirpHostTime() -> UInt64 {
        chirpHost.load(ordering: .acquiring)
    }

    private static let ioProc: AudioDeviceIOProc = { _, inNow, _, _, outOutputData, inOutputTime, refcon in
        guard let refcon else { return noErr }
        let speaker = Unmanaged<SpeakerOutput>.fromOpaque(refcon).takeUnretainedValue()
        let frames = min(speaker.frameCount(outOutputData), speaker.scratchFrames)
        guard frames > 0 else { return noErr }

        switch speaker.mode.load(ordering: .acquiring) {
        case SpeakerMode.silence.rawValue:
            speaker.renderScratch.update(repeating: 0, count: frames * 2)
        case SpeakerMode.chirp.rawValue:
            speaker.renderChirp(frames: frames, hostTime: hostTime(inOutputTime, fallback: inNow))
        default:
            speaker.reader.pull(frames: frames, outputRate: speaker.sampleRate, into: speaker.renderScratch)
            speaker.eq.process(speaker.renderScratch, frames: frames)
        }
        writeStereo(speaker.renderScratch, frames: frames, format: speaker.format, to: outOutputData)
        return noErr
    }

    private func renderChirp(frames: Int, hostTime: UInt64) {
        var cursor = chirpCursor.load(ordering: .acquiring)
        if cursor == 0 && chirpHost.load(ordering: .relaxed) == 0 {
            chirpHost.store(hostTime, ordering: .releasing)
        }
        let source = chirp
        let count = chirpCount
        for frame in 0..<frames {
            let sample: Float
            if let source, cursor < count {
                sample = source[cursor]
                cursor += 1
            } else {
                sample = 0
            }
            renderScratch[frame * 2] = sample
            renderScratch[frame * 2 + 1] = sample
        }
        chirpCursor.store(cursor, ordering: .releasing)
    }

    private func frameCount(_ bufferList: UnsafeMutablePointer<AudioBufferList>) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let first = buffers.first, format.mBytesPerFrame > 0 else { return 0 }
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            return Int(first.mDataByteSize) / Int(format.mBytesPerFrame)
        }
        return Int(first.mDataByteSize) / Int(format.mBytesPerFrame)
    }
}

private enum SpeakerMode: Int {
    case play = 0
    case silence = 1
    case chirp = 2
}
