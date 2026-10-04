import CoreAudio
import Foundation
import Synchronization

final class MicrophoneRecorder {
    private var deviceID = AudioDeviceID()
    private var ioProc: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var storage: UnsafeMutablePointer<Float>
    private let capacityFrames = 48_000 * 3
    private let writeFrame = Atomic<Int64>(0)
    private var localWrite: Int64 = 0
    private let startHost = Atomic<UInt64>(0)
    private var scratch: UnsafeMutablePointer<Float>

    var sampleRate: Double { format.mSampleRate }

    init() {
        storage = .allocate(capacity: capacityFrames)
        storage.initialize(repeating: 0, count: capacityFrames)
        scratch = .allocate(capacity: 16_384 * 2)
    }

    deinit {
        storage.deallocate()
        scratch.deallocate()
    }

    func start() throws {
        guard let mic = AudioDevices.builtInMicrophone() else {
            throw EngineError.noMicrophone
        }
        deviceID = mic.id
        format = try AudioDevices.streamFormat(mic.id, scope: kAudioObjectPropertyScopeInput)
        localWrite = 0
        writeFrame.store(0, ordering: .releasing)
        startHost.store(0, ordering: .releasing)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var proc: AudioDeviceIOProcID?
        try AudioDeviceCreateIOProcID(mic.id, Self.ioProc, refcon, &proc).check("Create microphone recorder")
        ioProc = proc
        try AudioDeviceStart(mic.id, proc).check("Start microphone")
    }

    func stop() {
        if let ioProc {
            AudioDeviceStop(deviceID, ioProc)
            AudioDeviceDestroyIOProcID(deviceID, ioProc)
        }
        ioProc = nil
    }

    func snapshot() -> (samples: [Float], startHost: UInt64) {
        let frames = Int(writeFrame.load(ordering: .acquiring))
        let count = min(frames, capacityFrames)
        let start = frames > capacityFrames ? frames - capacityFrames : 0
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let frame = (start + index) % capacityFrames
            samples[index] = storage[frame]
        }
        return (samples, startHost.load(ordering: .acquiring))
    }

    private static let ioProc: AudioDeviceIOProc = { _, inNow, inInputData, inInputTime, _, _, refcon in
        guard let refcon else { return noErr }
        let recorder = Unmanaged<MicrophoneRecorder>.fromOpaque(refcon).takeUnretainedValue()
        let frames = min(recorder.frameCount(inInputData), 16_384)
        guard frames > 0 else { return noErr }
        if recorder.startHost.load(ordering: .relaxed) == 0 {
            recorder.startHost.store(hostTime(inInputTime, fallback: inNow), ordering: .releasing)
        }
        guard copyInputAsStereo(inInputData, frames: frames, format: recorder.format, into: recorder.scratch) else {
            return noErr
        }
        for frame in 0..<frames {
            let mono = (recorder.scratch[frame * 2] + recorder.scratch[frame * 2 + 1]) * 0.5
            let index = Int(recorder.localWrite % Int64(recorder.capacityFrames))
            recorder.storage[index] = mono
            recorder.localWrite += 1
        }
        recorder.writeFrame.store(recorder.localWrite, ordering: .releasing)
        return noErr
    }

    private func frameCount(_ bufferList: UnsafePointer<AudioBufferList>) -> Int {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let first = buffers.first, format.mBytesPerFrame > 0 else { return 0 }
        return Int(first.mDataByteSize) / Int(format.mBytesPerFrame)
    }
}

enum EngineError: Error, LocalizedError, CustomStringConvertible {
    case notPaired
    case connectionFailed(String, Int32)
    case speakersMissing(String)
    case noMicrophone
    case cancelled
    case chirpFailed(String)
    case speakersDisconnected(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notPaired:
            return "Pair the Pulse 4 and the SRS-XB13 in Bluetooth settings first."
        case .connectionFailed(let name, let code):
            return "Couldn't connect to \(name) (\(code)). Turn both speakers on and try again."
        case .speakersMissing(let seen):
            return "Both speakers need to be on. Currently visible outputs: \(seen)."
        case .noMicrophone:
            return "The MacBook microphone isn't available."
        case .cancelled:
            return "Cancelled."
        case .chirpFailed(let detail):
            return detail
        case .speakersDisconnected(let missing):
            return "Connect both speakers before calibrating. Missing: \(missing)."
        }
    }
}

final class Engine {
    private let clock = SharedClock()
    private var tap: SystemAudioTap?
    private var pulse: SpeakerOutput?
    private var sony: SpeakerOutput?
    private var microphone: MicrophoneRecorder?
    private var restoreOutputUID: String?
    private var startToken = UUID()
    private var volumeMonitor: OutputVolumeMonitor?
    private var pulseTrim: Float = 0.8
    private var sonyTrim: Float = 1
    private var master: Float = 1
    var onMasterVolume: ((Float) -> Void)?
    private var pulseDelay = 0.0
    private var sonyDelay = 0.0
    private var pulseCut = BandCut.flat
    private var sonyCut = BandCut.flat
    private var toneEnabled = true
    private let measuring = Atomic<Bool>(false)
    private var silenceRecheckEnabled = false
    private var reportedMissing = Set<String>()
    var onNotice: ((EngineNotice) -> Void)?

    var measuredDelays: (pulse: Double, sony: Double) { (pulseDelay, sonyDelay) }

    func start(pulseGain: Float, sonyGain: Float, pulseDelay: Double, sonyDelay: Double, pulseCut: BandCut, sonyCut: BandCut, toneEnabled: Bool, silenceRecheck: Bool) async throws {
        let previous = try AudioDevices.defaultOutputUID()
        restoreOutputUID = previous
        UserDefaults.standard.set(previous, forKey: Store.restoreOutput)

        do {
            try await Task.detached(priority: .userInitiated) {
                try BluetoothSpeakers.connectPair()
            }.value
            let speakers = try await waitForSpeakers()
            if let previousID = AudioDevices.deviceID(forUID: previous) {
                try AudioDevices.setDefaultOutput(previousID)
                startVolumeMonitor(on: previousID)
            }
            let tap = SystemAudioTap(clock: clock)
            try tap.start(mute: .mutedWhenTapped)
            self.tap = tap

            let pulse = SpeakerOutput(device: speakers.pulse, clock: clock)
            try pulse.start()
            self.pulse = pulse
            pulseTrim = pulseGain
            pulse.reader.setDelay(pulseDelay)

            let sony = SpeakerOutput(device: speakers.sony, clock: clock)
            try sony.start()
            self.sony = sony
            sonyTrim = sonyGain
            sony.reader.setDelay(sonyDelay)
            applyGains()
            self.pulseDelay = pulseDelay
            self.sonyDelay = sonyDelay
            self.pulseCut = pulseCut
            self.sonyCut = sonyCut
            self.toneEnabled = toneEnabled
            self.silenceRecheckEnabled = silenceRecheck
            pulse.setTone(toneEnabled ? pulseCut : .flat)
            sony.setTone(toneEnabled ? sonyCut : .flat)
            let token = UUID()
            startToken = token
            let uid = previous
            Task {
                try? await Task.sleep(for: .seconds(1))
                guard self.startToken == token else { return }
                if let id = AudioDevices.deviceID(forUID: uid) {
                    try? AudioDevices.setDefaultOutput(id)
                }
            }
            startWatch(token: token)
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        startToken = UUID()
        measuring.store(false, ordering: .releasing)
        reportedMissing = []
        volumeMonitor?.stop()
        volumeMonitor = nil
        pulse?.stop()
        sony?.stop()
        microphone?.stop()
        tap?.stop()
        pulse = nil
        sony = nil
        microphone = nil
        tap = nil
        if let restoreOutputUID, let device = AudioDevices.deviceID(forUID: restoreOutputUID) {
            try? AudioDevices.setDefaultOutput(device)
            UserDefaults.standard.removeObject(forKey: Store.restoreOutput)
        }
        restoreOutputUID = nil
    }

    func setGains(pulse: Float, sony: Float) {
        pulseTrim = pulse
        sonyTrim = sony
        applyGains()
    }

    func setToneEnabled(_ enabled: Bool) {
        toneEnabled = enabled
        pulse?.setTone(enabled ? pulseCut : .flat)
        sony?.setTone(enabled ? sonyCut : .flat)
    }

    func requireConnectedSpeakers() throws {
        guard let pulse, let sony else { throw EngineError.cancelled }
        var missing: [String] = []
        let outputs = AudioDevices.outputs()
        if !outputs.contains(where: { $0.uid == pulse.device.uid }) {
            missing.append("Pulse 4")
        }
        if !outputs.contains(where: { $0.uid == sony.device.uid }) {
            missing.append("SRS-XB13")
        }
        if !missing.isEmpty {
            throw EngineError.speakersDisconnected(missing.joined(separator: " and "))
        }
    }

    func calibrate(progress: (String, String) async -> Void) async throws -> Calibration {
        while !measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { measuring.store(false, ordering: .releasing) }
        guard let pulse, let sony else { throw EngineError.cancelled }
        try requireConnectedSpeakers()
        await progress(
            "Checking speakers",
            "The Pulse 4 and the SRS-XB13 are both connected."
        )
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        defer {
            microphone.stop()
            self.microphone = nil
            pulse.resume()
            sony.resume()
        }
        await progress(
            "Testing the Pulse 4",
            "Playing a sweep through the Pulse 4. The Mac microphone is listening for delay and tone. That speaker is turned up for the test, then put back."
        )
        let pulseResult = try await measure(speaker: pulse, other: sony, microphone: microphone, name: "Pulse 4")
        await progress(
            "Testing the SRS-XB13",
            "Playing a sweep through the SRS-XB13. The Mac microphone is listening for delay and tone. That speaker is turned up for the test, then put back."
        )
        let sonyResult = try await measure(speaker: sony, other: pulse, microphone: microphone, name: "SRS-XB13")
        await progress(
            "Comparing the two",
            "Setting the delay, and sending each part of the sound to the speaker that reproduces it better."
        )
        let slowest = max(pulseResult.latency, sonyResult.latency)
        pulseDelay = max(0, slowest - pulseResult.latency)
        sonyDelay = max(0, slowest - sonyResult.latency)
        pulse.reader.setDelay(pulseDelay)
        sony.reader.setDelay(sonyDelay)
        let cuts = ToneSplit.assignment(pulse: pulseResult.shape, sony: sonyResult.shape)
        pulseCut = cuts.pulse
        sonyCut = cuts.sony
        silenceRecheckEnabled = true
        pulse.setTone(toneEnabled ? cuts.pulse : .flat)
        sony.setTone(toneEnabled ? cuts.sony : .flat)
        return Calibration(
            pulseDelay: pulseDelay,
            sonyDelay: sonyDelay,
            pulseCut: cuts.pulse,
            sonyCut: cuts.sony
        )
    }

    private func measure(
        speaker: SpeakerOutput,
        other: SpeakerOutput,
        microphone: MicrophoneRecorder,
        name: String
    ) async throws -> (latency: Double, shape: BandLevel) {
        microphone.stop()
        try microphone.start()
        try await Task.sleep(for: .milliseconds(100))
        other.silence()
        let savedLevel = DeviceLevel.boost(speaker.device.id)
        defer { DeviceLevel.restore(speaker.device.id, savedLevel) }
        let playback = Chirp.make(sampleRate: speaker.sampleRate)
        speaker.playChirp(playback)
        let host = try await waitForHostTime(on: speaker)
        let listen = Chirp.duration + 0.9
        try await Task.sleep(for: .milliseconds(Int(listen * 1_000)))
        speaker.silence()
        other.silence()

        let recording = microphone.snapshot()
        guard recording.startHost != 0 else {
            throw EngineError.chirpFailed("The microphone didn't start.")
        }
        let template = Chirp.make(sampleRate: microphone.sampleRate)
        let located: LocatedChirp
        do {
            located = try Chirp.locate(template: template, in: recording.samples)
        } catch {
            throw EngineError.chirpFailed("Couldn't hear the \(name). \(error)")
        }
        let send = HostClock.seconds(host)
        let receiveStart = HostClock.seconds(recording.startHost)
        let arrival = receiveStart + located.sample / microphone.sampleRate
        let latency = arrival - send
        guard latency > 0, latency < 1.5 else {
            throw EngineError.chirpFailed("The \(name) measurement was \(Int(latency * 1000)) ms, which is outside the range this can correct.")
        }
        let shape = toneShape(recording: recording.samples, locatedSample: located.sample, sampleRate: microphone.sampleRate)
        return (latency, shape)
    }

    private func toneShape(recording: [Float], locatedSample: Double, sampleRate: Double) -> BandLevel {
        let start = min(max(Int(locatedSample), 0), recording.count)
        let length = min(recording.count - start, max(Int(Chirp.duration * sampleRate), 1))
        guard length > 32 else {
            return BandLevel(low: 0, mid: 0, high: 0)
        }
        return ToneSplit.shape(samples: Array(recording[start..<(start + length)]), sampleRate: sampleRate)
    }

    private func waitForHostTime(on speaker: SpeakerOutput) async throws -> UInt64 {
        for _ in 0..<20 {
            let host = speaker.takeChirpHostTime()
            if host != 0 { return host }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw EngineError.chirpFailed("\(speaker.device.name) didn't play the chirp.")
    }

    private func waitForSpeakers() async throws -> (pulse: AudioDeviceInfo, sony: AudioDeviceInfo) {
        for _ in 0..<24 {
            if let match = AudioDevices.matchSpeakers() {
                return match
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let names = AudioDevices.outputs().map(\.name).joined(separator: ", ")
        throw EngineError.speakersMissing(names.isEmpty ? "none" : names)
    }

    private func startVolumeMonitor(on device: AudioDeviceID) {
        volumeMonitor?.stop()
        let monitor = OutputVolumeMonitor(device: device)
        monitor.onChange = { [weak self] value in
            guard let self else { return }
            self.master = value
            self.applyGains()
            self.onMasterVolume?(value)
        }
        monitor.start()
        volumeMonitor = monitor
    }

    private func applyGains() {
        pulse?.reader.setGain(pulseTrim * master)
        sony?.reader.setGain(sonyTrim * master)
    }

    private func startWatch(token: UUID) {
        Task { [weak self] in
            var heardAudio = false
            var recheckArmed = false
            var nextReconnect = Date.distantPast
            while let self, self.startToken == token, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard self.startToken == token else { return }
                if self.measuring.load(ordering: .acquiring) { continue }
                if Date() >= nextReconnect {
                    let restored = await self.recoverDisconnectedSpeakers()
                    if restored {
                        nextReconnect = Date().addingTimeInterval(2)
                    } else if self.missingSpeakerNames().isEmpty == false {
                        nextReconnect = Date().addingTimeInterval(8)
                    }
                }
                let silence = self.clock.silenceSeconds()
                if silence < 0.5 {
                    heardAudio = true
                    recheckArmed = true
                }
                guard heardAudio, recheckArmed, silence > 4, self.silenceRecheckEnabled else { continue }
                guard self.missingSpeakerNames().isEmpty else { continue }
                guard self.measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged else { continue }
                recheckArmed = false
                await self.recheckDelay()
                self.measuring.store(false, ordering: .releasing)
            }
        }
    }

    private func missingSpeakerNames() -> [String] {
        let outputs = AudioDevices.outputs()
        var missing: [String] = []
        if let pulse, !outputs.contains(where: { $0.uid == pulse.device.uid }) {
            missing.append("Pulse 4")
        }
        if let sony, !outputs.contains(where: { $0.uid == sony.device.uid }) {
            missing.append("SRS-XB13")
        }
        return missing
    }

    private func recoverDisconnectedSpeakers() async -> Bool {
        let missing = missingSpeakerNames()
        guard !missing.isEmpty else { return false }
        for name in missing where !reportedMissing.contains(name) {
            reportedMissing.insert(name)
            onNotice?(.speakerLost(name))
        }
        try? await Task.detached(priority: .userInitiated) {
            try BluetoothSpeakers.connectPair()
        }.value
        for _ in 0..<12 {
            guard let match = AudioDevices.matchSpeakers() else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            var restored = false
            if missing.contains("Pulse 4") {
                adopt(match.pulse, kind: .pulse)
                reportedMissing.remove("Pulse 4")
                onNotice?(.speakerBack("Pulse 4"))
                restored = true
            }
            if missing.contains("SRS-XB13") {
                adopt(match.sony, kind: .sony)
                reportedMissing.remove("SRS-XB13")
                onNotice?(.speakerBack("SRS-XB13"))
                restored = true
            }
            return restored
        }
        return false
    }

    private func adopt(_ info: AudioDeviceInfo, kind: SpeakerKind) {
        let previous = kind == .pulse ? pulse : sony
        previous?.stop()
        let output = SpeakerOutput(device: info, clock: clock)
        do {
            try output.start()
        } catch {
            return
        }
        let delay = kind == .pulse ? pulseDelay : sonyDelay
        let cut = kind == .pulse ? pulseCut : sonyCut
        output.reader.setDelay(delay)
        output.setTone(toneEnabled ? cut : .flat)
        if kind == .pulse {
            pulse = output
        } else {
            sony = output
        }
        applyGains()
    }

    private func recheckDelay() async {
        guard let pulse, let sony else { return }
        onNotice?(.rechecking)
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        defer {
            microphone.stop()
            self.microphone = nil
            pulse.resume()
            sony.resume()
        }
        do {
            let pulseResult = try await measure(speaker: pulse, other: sony, microphone: microphone, name: "Pulse 4")
            let sonyResult = try await measure(speaker: sony, other: pulse, microphone: microphone, name: "SRS-XB13")
            let slowest = max(pulseResult.latency, sonyResult.latency)
            pulseDelay = max(0, slowest - pulseResult.latency)
            sonyDelay = max(0, slowest - sonyResult.latency)
            pulse.reader.setDelay(pulseDelay)
            sony.reader.setDelay(sonyDelay)
            onNotice?(.delaysUpdated(pulse: pulseDelay, sony: sonyDelay))
        } catch {
            onNotice?(.recheckFailed(error.localizedDescription))
        }
    }
}

enum Store {
    static let pulseVolume = "pulseVolume"
    static let sonyVolume = "sonyVolume"
    static let pulseDelay = "pulseDelay"
    static let sonyDelay = "sonyDelay"
    static let restoreOutput = "restoreOutput"
    static let toneMeasured = "toneMeasured"
    static let pulseLow = "pulseLowDB"
    static let pulseMid = "pulseMidDB"
    static let pulseHigh = "pulseHighDB"
    static let sonyLow = "sonyLowDB"
    static let sonyMid = "sonyMidDB"
    static let sonyHigh = "sonyHighDB"
    static let toneEnabled = "toneEnabled"
}

struct Calibration {
    var pulseDelay: Double
    var sonyDelay: Double
    var pulseCut: BandCut
    var sonyCut: BandCut
}

enum EngineNotice {
    case rechecking
    case delaysUpdated(pulse: Double, sony: Double)
    case recheckFailed(String)
    case speakerLost(String)
    case speakerBack(String)
}

private enum SpeakerKind {
    case pulse
    case sony
}

enum OutputRestore {
    static func recoverIfNeeded() {
        guard let uid = UserDefaults.standard.string(forKey: Store.restoreOutput),
              let id = AudioDevices.deviceID(forUID: uid) else {
            return
        }
        try? AudioDevices.setDefaultOutput(id)
        UserDefaults.standard.removeObject(forKey: Store.restoreOutput)
    }
}
