import CoreAudio
import Foundation

struct AudioStatus: Error, CustomStringConvertible {
    var status: OSStatus
    var context: String

    var description: String {
        "\(context) failed (\(status.fourCharacterCode))"
    }
}

extension OSStatus {
    var fourCharacterCode: String {
        let bytes: [UInt8] = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) {
            return "'" + String(bytes: bytes, encoding: .ascii)! + "'"
        }
        return String(self)
    }

    func check(_ context: String) throws {
        if self != noErr {
            throw AudioStatus(status: self, context: context)
        }
    }
}

struct AudioDeviceInfo: Identifiable, Equatable {
    var id: AudioDeviceID
    var uid: String
    var name: String
    var outputChannels: Int

    var isPulse: Bool {
        let lower = name.lowercased()
        return lower.contains("pulse")
    }

    var isSony: Bool {
        let lower = name.lowercased()
        return lower.contains("xb13")
    }
}

enum AudioDevices {
    static func outputs() -> [AudioDeviceInfo] {
        deviceIDs().compactMap { id in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  outputChannelCount(id) > 0 else {
                return nil
            }
            return AudioDeviceInfo(id: id, uid: uid, name: name, outputChannels: outputChannelCount(id))
        }
    }

    static func matchSpeakers() -> (pulse: AudioDeviceInfo, sony: AudioDeviceInfo)? {
        let devices = outputs()
        guard let pulse = devices.filter(\.isPulse).sorted(by: { $0.name.count > $1.name.count }).first,
              let sony = devices.filter(\.isSony).first,
              pulse.id != sony.id else {
            return nil
        }
        return (pulse, sony)
    }

    static func defaultOutputUID() throws -> String {
        let device = try defaultOutputID()
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID) else {
            throw AudioStatus(status: kAudioHardwareBadDeviceError, context: "Read output UID")
        }
        return uid
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = systemAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let uidRef = uid as CFString
        let status = withUnsafePointer(to: uidRef) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &device
            )
        }
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    static func defaultOutputID() throws -> AudioDeviceID {
        var device = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        try AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        ).check("Read default output")
        return device
    }

    static func setDefaultOutput(_ device: AudioDeviceID) throws {
        var device = device
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        try AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &device
        ).check("Restore output device")
    }

    static func builtInMicrophone() -> AudioDeviceInfo? {
        deviceIDs().compactMap { id -> AudioDeviceInfo? in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  inputChannelCount(id) > 0 else {
                return nil
            }
            return AudioDeviceInfo(id: id, uid: uid, name: name, outputChannels: 0)
        }
        .first { $0.name.localizedCaseInsensitiveContains("microphone") }
    }

    static func streamFormat(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioObjectGetPropertyData(device, &address, 0, nil, &size, &format).check("Read stream format")
        return format
    }

    static func nominalSampleRate(_ device: AudioDeviceID) throws -> Double {
        var rate = Float64()
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        try AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate).check("Read sample rate")
        return rate
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private static func outputChannelCount(_ device: AudioDeviceID) -> Int {
        channelCount(device, scope: kAudioObjectPropertyScopeOutput)
    }

    private static func inputChannelCount(_ device: AudioDeviceID) -> Int {
        channelCount(device, scope: kAudioObjectPropertyScopeInput)
    }

    private static func channelCount(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

enum HostClock {
    private static let scale: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    static func seconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * scale
    }
}

func hostTime(_ stamp: UnsafePointer<AudioTimeStamp>?, fallback: UnsafePointer<AudioTimeStamp>) -> UInt64 {
    if let stamp, stamp.pointee.mFlags.contains(.hostTimeValid) {
        return stamp.pointee.mHostTime
    }
    if fallback.pointee.mFlags.contains(.hostTimeValid) {
        return fallback.pointee.mHostTime
    }
    return mach_absolute_time()
}

func copyInputAsStereo(
    _ bufferList: UnsafePointer<AudioBufferList>,
    frames: Int,
    format: AudioStreamBasicDescription,
    into destination: UnsafeMutablePointer<Float>
) -> Bool {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    guard frames > 0, !buffers.isEmpty else { return false }
    let channels = Int(format.mChannelsPerFrame)
    guard channels > 0 else { return false }

    if format.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
        if format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
            for frame in 0..<frames {
                destination[frame * 2] = left[frame]
                destination[frame * 2 + 1] = right?[frame] ?? left[frame]
            }
            return true
        }
        guard let source = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
        if channels == 1 {
            for frame in 0..<frames {
                destination[frame * 2] = source[frame]
                destination[frame * 2 + 1] = source[frame]
            }
        } else {
            for frame in 0..<frames {
                destination[frame * 2] = source[frame * channels]
                destination[frame * 2 + 1] = source[frame * channels + 1]
            }
        }
        return true
    }

    if format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0 && format.mBitsPerChannel == 16 {
        guard let source = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return false }
        let stride = max(channels, 1)
        let scale = 1 / Float(Int16.max)
        for frame in 0..<frames {
            let left = Float(source[frame * stride]) * scale
            let right = stride > 1 ? Float(source[frame * stride + 1]) * scale : left
            destination[frame * 2] = left
            destination[frame * 2 + 1] = right
        }
        return true
    }

    return false
}

func writeStereo(
    _ source: UnsafePointer<Float>,
    frames: Int,
    format: AudioStreamBasicDescription,
    to bufferList: UnsafeMutablePointer<AudioBufferList>
) {
    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    guard frames > 0, !buffers.isEmpty else { return }
    let channels = Int(format.mChannelsPerFrame)
    let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
    let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    let isSignedInt = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0

    if isFloat && isNonInterleaved {
        guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        for frame in 0..<frames {
            left[frame] = source[frame * 2]
            right?[frame] = source[frame * 2 + 1]
        }
        return
    }

    if isFloat {
        guard let destination = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        if channels <= 1 {
            for frame in 0..<frames {
                destination[frame] = (source[frame * 2] + source[frame * 2 + 1]) * 0.5
            }
        } else {
            for frame in 0..<frames {
                destination[frame * channels] = source[frame * 2]
                destination[frame * channels + 1] = source[frame * 2 + 1]
                for extra in 2..<channels {
                    destination[frame * channels + extra] = 0
                }
            }
        }
        return
    }

    if isSignedInt && format.mBitsPerChannel == 16 {
        guard let destination = buffers[0].mData?.assumingMemoryBound(to: Int16.self) else { return }
        let stride = max(channels, 1)
        for frame in 0..<frames {
            let left = max(-1, min(1, source[frame * 2]))
            let right = max(-1, min(1, source[frame * 2 + 1]))
            if stride == 1 {
                destination[frame] = Int16(((left + right) * 0.5) * Float(Int16.max))
            } else {
                destination[frame * stride] = Int16(left * Float(Int16.max))
                destination[frame * stride + 1] = Int16(right * Float(Int16.max))
            }
        }
    }
}

struct SavedLevel {
    var volumes: [(AudioObjectPropertyElement, Float)]
    var muted: UInt32?
}

enum DeviceLevel {
    static func userScalar(_ device: AudioDeviceID) -> Float {
        if let muted = muteValue(device), muted != 0 { return 0 }
        let values = volumeElements(device).compactMap { readFloat(device, kAudioDevicePropertyVolumeScalar, $0) }
        guard !values.isEmpty else { return 1 }
        return values.reduce(0, +) / Float(values.count)
    }

    static func boost(_ device: AudioDeviceID) -> SavedLevel {
        let elements = volumeElements(device)
        let saved = SavedLevel(
            volumes: elements.compactMap { element in
                readFloat(device, kAudioDevicePropertyVolumeScalar, element).map { (element, $0) }
            },
            muted: muteValue(device)
        )
        if saved.muted != nil {
            writeUInt32(device, kAudioDevicePropertyMute, 0, element: kAudioObjectPropertyElementMain)
        }
        for (element, _) in saved.volumes {
            writeFloat(device, kAudioDevicePropertyVolumeScalar, 1, element: element)
        }
        return saved
    }

    static func restore(_ device: AudioDeviceID, _ saved: SavedLevel) {
        for (element, value) in saved.volumes {
            writeFloat(device, kAudioDevicePropertyVolumeScalar, value, element: element)
        }
        if let muted = saved.muted {
            writeUInt32(device, kAudioDevicePropertyMute, muted, element: kAudioObjectPropertyElementMain)
        }
    }

    static func volumeElements(_ device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        [kAudioObjectPropertyElementMain, 1, 2].filter { element in
            has(device, kAudioDevicePropertyVolumeScalar, element)
        }
    }

    private static func muteValue(_ device: AudioDeviceID) -> UInt32? {
        guard has(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain) else { return nil }
        return readUInt32(device, kAudioDevicePropertyMute, kAudioObjectPropertyElementMain)
    }

    private static func has(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Bool {
        var address = outputAddress(selector, element)
        return AudioObjectHasProperty(device, &address)
    }

    private static func readFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> Float? {
        var address = outputAddress(selector, element)
        var value = Float32()
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeFloat(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: Float, element: AudioObjectPropertyElement) {
        var address = outputAddress(selector, element)
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private static func readUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> UInt32? {
        var address = outputAddress(selector, element)
        var value = UInt32()
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeUInt32(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector, _ value: UInt32, element: AudioObjectPropertyElement) {
        var address = outputAddress(selector, element)
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector, _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: element
        )
    }
}

final class OutputVolumeMonitor {
    var onChange: (Float) -> Void = { _ in }
    private let device: AudioDeviceID
    private var addresses: [AudioObjectPropertyAddress] = []
    private var block: AudioObjectPropertyListenerBlock?

    init(device: AudioDeviceID) {
        self.device = device
    }

    func start() {
        var watched: [AudioObjectPropertyAddress] = []
        for element in DeviceLevel.volumeElements(device) {
            watched.append(AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            ))
        }
        var mute = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &mute) {
            watched.append(mute)
        }
        addresses = watched
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange(DeviceLevel.userScalar(self.device))
        }
        block = listener
        for index in addresses.indices {
            AudioObjectAddPropertyListenerBlock(device, &addresses[index], .main, listener)
        }
        onChange(DeviceLevel.userScalar(device))
    }

    func stop() {
        guard let block else { return }
        for index in addresses.indices {
            AudioObjectRemovePropertyListenerBlock(device, &addresses[index], .main, block)
        }
        self.block = nil
    }
}
