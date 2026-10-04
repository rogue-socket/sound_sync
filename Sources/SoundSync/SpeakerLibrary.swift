import Foundation

struct SpeakerRecord: Identifiable, Equatable {
    var id: String
    var name: String
    var address: String?
    var included: Bool
    var volume: Double
    var delay: Double
    var lowDB: Float
    var midDB: Float
    var highDB: Float
    var available: Bool

    var cut: BandCut {
        BandCut(lowDB: lowDB, midDB: midDB, highDB: highDB)
    }

    func setup() -> SpeakerSetup {
        SpeakerSetup(
            id: id,
            name: name,
            address: address,
            gain: Float(volume),
            delay: delay,
            cut: cut
        )
    }
}

private struct StoredSpeaker: Codable {
    var id: String
    var name: String
    var address: String?
    var included: Bool
    var volume: Double
    var delay: Double
    var lowDB: Float
    var midDB: Float
    var highDB: Float
}

enum SpeakerLibrary {
    static func load() -> [SpeakerRecord] {
        let discovered = BluetoothSpeakers.discover()
        let saved = decode()
        if UserDefaults.standard.object(forKey: Store.speakerRecords) == nil {
            return migrated(discovered)
        }
        return merge(saved: saved, discovered: discovered).filter(\.included)
    }

    static func save(_ records: [SpeakerRecord]) {
        let stored = records.map {
            StoredSpeaker(
                id: $0.id,
                name: $0.name,
                address: $0.address,
                included: $0.included,
                volume: $0.volume,
                delay: $0.delay,
                lowDB: $0.lowDB,
                midDB: $0.midDB,
                highDB: $0.highDB
            )
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Store.speakerRecords)
    }

    private static func migrated(_ discovered: [DiscoveredSpeaker]) -> [SpeakerRecord] {
        let defaults = UserDefaults.standard
        let measured = defaults.bool(forKey: Store.toneMeasured)
        let records = discovered.map { device -> SpeakerRecord in
            let legacy = legacyMatch(device.name)
            return SpeakerRecord(
                id: device.id,
                name: device.name,
                address: device.address,
                included: legacy != nil,
                volume: legacy?.volume ?? 0.8,
                delay: legacy?.delay ?? 0,
                lowDB: measured ? (legacy?.low ?? 0) : 0,
                midDB: measured ? (legacy?.mid ?? 0) : 0,
                highDB: measured ? (legacy?.high ?? 0) : 0,
                available: device.connected || device.address != nil
            )
        }
        return records.filter(\.included)
    }

    static func available(excluding records: [SpeakerRecord]) -> [DiscoveredSpeaker] {
        BluetoothSpeakers.discover().filter { device in
            !records.contains { record in
                record.id == device.id || SpeakerNames.match(record.name, device.name)
            }
        }
    }

    static func applyingDiscovery(_ records: [SpeakerRecord]) -> [SpeakerRecord] {
        let discovered = BluetoothSpeakers.discover()
        return records.map { record in
            var copy = record
            if let device = discovered.first(where: { $0.id == record.id || SpeakerNames.match($0.name, record.name) }) {
                copy.name = device.name
                copy.address = device.address ?? copy.address
                copy.available = device.connected
            } else {
                copy.available = false
            }
            copy.included = true
            return copy
        }
    }

    private static func legacyMatch(_ name: String) -> (volume: Double, delay: Double, low: Float, mid: Float, high: Float)? {
        let defaults = UserDefaults.standard
        let lower = name.lowercased()
        let prefix: String
        let volumeKey: String
        let delayKey: String
        if lower.contains("pulse") {
            prefix = "pulse"
            volumeKey = Store.pulseVolume
            delayKey = Store.pulseDelay
        } else if lower.contains("xb13") {
            prefix = "sony"
            volumeKey = Store.sonyVolume
            delayKey = Store.sonyDelay
        } else {
            return nil
        }
        let volume = defaults.object(forKey: volumeKey) as? Double ?? (prefix == "sony" ? 1.0 : 0.8)
        return (
            volume,
            defaults.double(forKey: delayKey),
            Float(defaults.double(forKey: "\(prefix)LowDB")),
            Float(defaults.double(forKey: "\(prefix)MidDB")),
            Float(defaults.double(forKey: "\(prefix)HighDB"))
        )
    }

    private static func merge(saved: [StoredSpeaker], discovered: [DiscoveredSpeaker]) -> [SpeakerRecord] {
        var used = Set<Int>()
        var result: [SpeakerRecord] = []
        for device in discovered {
            let index = saved.firstIndex { $0.id == device.id }
                ?? saved.firstIndex { SpeakerNames.match($0.name, device.name) }
            if let index, !used.contains(index) {
                used.insert(index)
                let stored = saved[index]
                result.append(SpeakerRecord(
                    id: device.id,
                    name: device.name,
                    address: device.address,
                    included: stored.included,
                    volume: stored.volume,
                    delay: stored.delay,
                    lowDB: stored.lowDB,
                    midDB: stored.midDB,
                    highDB: stored.highDB,
                    available: true
                ))
            } else {
                result.append(SpeakerRecord(
                    id: device.id,
                    name: device.name,
                    address: device.address,
                    included: false,
                    volume: 0.8,
                    delay: 0,
                    lowDB: 0,
                    midDB: 0,
                    highDB: 0,
                    available: true
                ))
            }
        }
        for (index, stored) in saved.enumerated() where !used.contains(index) && stored.included {
            result.append(SpeakerRecord(
                id: stored.id,
                name: stored.name,
                address: stored.address,
                included: true,
                volume: stored.volume,
                delay: stored.delay,
                lowDB: stored.lowDB,
                midDB: stored.midDB,
                highDB: stored.highDB,
                available: false
            ))
        }
        return result
    }

    private static func decode() -> [StoredSpeaker] {
        guard let data = UserDefaults.standard.data(forKey: Store.speakerRecords),
              let stored = try? JSONDecoder().decode([StoredSpeaker].self, from: data) else {
            return []
        }
        return stored
    }
}
