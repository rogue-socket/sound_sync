import Foundation
import IOBluetooth

enum BluetoothSpeakers {
    static func connectPair() throws {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let pulse = paired.first { ($0.name ?? "").localizedCaseInsensitiveContains("pulse") }
        let sony = paired.first { ($0.name ?? "").localizedCaseInsensitiveContains("xb13") }
        guard let pulse, let sony else {
            throw EngineError.notPaired
        }
        try open(pulse)
        try open(sony)
    }

    private static func open(_ device: IOBluetoothDevice) throws {
        if device.isConnected() { return }
        let result = device.openConnection()
        if result != kIOReturnSuccess {
            throw EngineError.connectionFailed(device.name ?? "speaker", result)
        }
    }
}
