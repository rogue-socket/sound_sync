import CoreAudio
import Foundation

final class SystemAudioTap {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let clock: SharedClock
    private var format = AudioStreamBasicDescription()
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 16_384

    init(clock: SharedClock) {
        self.clock = clock
        scratch = .allocate(capacity: scratchFrames * 2)
    }

    deinit {
        scratch.deallocate()
    }

    func start(mute: CATapMuteBehavior) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Sound Sync"
        description.isPrivate = true
        description.isExclusive = true
        description.muteBehavior = mute
        description.uuid = UUID()
        if #available(macOS 26.0, *) {
            description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.yashagrawal.soundsync"]
        }

        var created = AudioObjectID(kAudioObjectUnknown)
        try AudioHardwareCreateProcessTap(description, &created).check("Create system audio tap")
        tapID = created

        let tapUID = Self.tapUID(created) ?? description.uuid.uuidString
        let aggregateUID = "com.yashagrawal.soundsync.\(UUID().uuidString)"
        let descriptionDictionary: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sound Sync Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: 0,
                ],
            ],
        ]

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try AudioHardwareCreateAggregateDevice(descriptionDictionary as CFDictionary, &aggregate)
            .check("Create tap aggregate")
        aggregateID = aggregate
        format = try AudioDevices.streamFormat(aggregate, scope: kAudioObjectPropertyScopeInput)
        clock.setSampleRate(format.mSampleRate)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var proc: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcID(aggregate, Self.ioProc, refcon, &proc).check("Create tap IO proc")
        ioProc = proc
        try AudioDeviceStart(aggregate, proc).check("Start system audio tap")
    }

    func stop() {
        if let ioProc, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private static let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, refcon in
        guard let refcon else { return noErr }
        let tap = Unmanaged<SystemAudioTap>.fromOpaque(refcon).takeUnretainedValue()
        let frames = Int(inInputData.pointee.mBuffers.mDataByteSize) / max(Int(tap.format.mBytesPerFrame), 1)
        let bufferFrames = min(frames, tap.scratchFrames)
        guard bufferFrames > 0 else { return noErr }
        if copyInputAsStereo(inInputData, frames: bufferFrames, format: tap.format, into: tap.scratch) {
            tap.clock.append(tap.scratch, frames: bufferFrames)
        }
        return noErr
    }

    private static func tapUID(_ tap: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }
}
