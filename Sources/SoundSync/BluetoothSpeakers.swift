import Foundation
import IOBluetooth

struct DiscoveredSpeaker: Equatable, Identifiable {
    var id: String
    var name: String
    var address: String?
    var connected: Bool
}

enum SpeakerNames {
    static func match(_ audioName: String, _ bluetoothName: String) -> Bool {
        let left = audioName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let right = bluetoothName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard left.count >= 3, right.count >= 3 else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default:
            return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }
}

enum BluetoothSpeakers {
    static func discover() -> [DiscoveredSpeaker] {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let outputs = AudioDevices.bluetoothOutputs()
        var speakers: [DiscoveredSpeaker] = []
        for device in paired where isPlaybackSpeaker(device) {
            let name = (device.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let address = device.addressString?.lowercased()
            let id = address ?? "name:\(name.lowercased())"
            guard !speakers.contains(where: { $0.id == id }) else { continue }
            let connected = outputs.contains { SpeakerNames.match($0.name, name) }
            speakers.append(DiscoveredSpeaker(id: id, name: name, address: address, connected: connected))
        }
        for output in outputs {
            guard !speakers.contains(where: { SpeakerNames.match(output.name, $0.name) }) else { continue }
            speakers.append(DiscoveredSpeaker(
                id: "uid:\(output.uid)",
                name: output.name,
                address: nil,
                connected: true
            ))
        }
        return speakers.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func connect(_ speakers: [SpeakerSetup]) throws {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let outputs = AudioDevices.bluetoothOutputs()
        for speaker in speakers {
            if let device = paired.first(where: { matches($0, speaker) }) {
                try open(device)
                continue
            }
            if outputs.contains(where: { SpeakerNames.match($0.name, speaker.name) }) {
                continue
            }
            throw EngineError.notPaired(speaker.name)
        }
    }

    private static func matches(_ device: IOBluetoothDevice, _ speaker: SpeakerSetup) -> Bool {
        if let address = speaker.address, device.addressString?.lowercased() == address {
            return true
        }
        let name = device.name ?? ""
        return SpeakerNames.match(name, speaker.name)
    }

    private static func isPlaybackSpeaker(_ device: IOBluetoothDevice) -> Bool {
        guard device.deviceClassMajor == kBluetoothDeviceClassMajorAudio else { return false }
        let minor = device.deviceClassMinor
        let skipped: [BluetoothDeviceClassMinor] = [
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioMicrophone),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioVideoCamera),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioCamcorder),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioVideoMonitor),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioVCR),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioSetTopBox),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioVideoConferencing),
            BluetoothDeviceClassMinor(kBluetoothDeviceClassMinorAudioGamingToy),
        ]
        return !skipped.contains(minor)
    }

    private static func open(_ device: IOBluetoothDevice) throws {
        if device.isConnected() { return }
        let result = device.openConnection()
        if result != kIOReturnSuccess {
            throw EngineError.connectionFailed(device.name ?? "speaker", result)
        }
    }
}
