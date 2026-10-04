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

struct SpeakerSetup {
    var id: String
    var name: String
    var address: String?
    var gain: Float
    var delay: Double
    var cut: BandCut
}

enum EngineError: Error, LocalizedError, CustomStringConvertible {
    case notPaired(String)
    case needTwoSpeakers
    case connectionFailed(String, Int32)
    case speakersMissing(String, String)
    case noMicrophone
    case cancelled
    case chirpFailed(String)
    case speakersDisconnected(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .notPaired(let name):
            return "\(name) isn't paired. Pair it in Bluetooth settings, then try again."
        case .needTwoSpeakers:
            return "Check at least two speakers. Sync needs more than one."
        case .connectionFailed(let name, let code):
            return "Couldn't connect to \(name) (\(code)). Turn that speaker on and try again."
        case .speakersMissing(let missing, let seen):
            return "\(missing) didn't show up as audio outputs. Turn them on. Currently visible: \(seen)."
        case .noMicrophone:
            return "The MacBook microphone isn't available."
        case .cancelled:
            return "Cancelled."
        case .chirpFailed(let detail):
            return detail
        case .speakersDisconnected(let missing):
            return "Connect these speakers before calibrating: \(missing)."
        }
    }
}

final class Engine {
    private struct ActiveSpeaker {
        var id: String
        var name: String
        var output: SpeakerOutput
        var trim: Float
        var delay: Double
        var cut: BandCut
    }

    private let clock = SharedClock()
    private var tap: SystemAudioTap?
    private var speakers: [ActiveSpeaker] = []
    private var wanted: [SpeakerSetup] = []
    private var microphone: MicrophoneRecorder?
    private var restoreOutputUID: String?
    private var startToken = UUID()
    private var volumeMonitor: OutputVolumeMonitor?
    private var master: Float = 1
    var onMasterVolume: ((Float) -> Void)?
    private var toneEnabled = true
    private let measuring = Atomic<Bool>(false)
    private var silenceRecheckEnabled = false
    private var reportedMissing = Set<String>()
    var onNotice: ((EngineNotice) -> Void)?

    func start(_ setups: [SpeakerSetup], toneEnabled: Bool, silenceRecheck: Bool) async throws {
        guard setups.count >= 2 else { throw EngineError.needTwoSpeakers }
        let previous = try AudioDevices.defaultOutputUID()
        restoreOutputUID = previous
        UserDefaults.standard.set(previous, forKey: Store.restoreOutput)
        wanted = setups

        do {
            try await Task.detached(priority: .userInitiated) {
                try BluetoothSpeakers.connect(setups)
            }.value
            let devices = try await waitForSpeakers(setups)
            if let previousID = AudioDevices.deviceID(forUID: previous) {
                try AudioDevices.setDefaultOutput(previousID)
                startVolumeMonitor(on: previousID)
            }
            let tap = SystemAudioTap(clock: clock)
            try tap.start(mute: .mutedWhenTapped)
            self.tap = tap
            self.toneEnabled = toneEnabled
            self.silenceRecheckEnabled = silenceRecheck
            speakers = []
            for (setup, device) in zip(setups, devices) {
                let output = SpeakerOutput(device: device, clock: clock)
                try output.start()
                output.reader.setDelay(setup.delay)
                output.setTone(toneEnabled ? setup.cut : .flat)
                speakers.append(ActiveSpeaker(
                    id: setup.id,
                    name: setup.name,
                    output: output,
                    trim: setup.gain,
                    delay: setup.delay,
                    cut: setup.cut
                ))
            }
            applyGains()
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
        for speaker in speakers {
            speaker.output.stop()
        }
        speakers = []
        wanted = []
        microphone?.stop()
        tap?.stop()
        microphone = nil
        tap = nil
        if let restoreOutputUID, let device = AudioDevices.deviceID(forUID: restoreOutputUID) {
            try? AudioDevices.setDefaultOutput(device)
            UserDefaults.standard.removeObject(forKey: Store.restoreOutput)
        }
        restoreOutputUID = nil
    }

    func setGain(id: String, gain: Float) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].trim = gain
        applyGains()
    }

    func setToneEnabled(_ enabled: Bool) {
        toneEnabled = enabled
        for speaker in speakers {
            speaker.output.setTone(enabled ? speaker.cut : .flat)
        }
    }

    func requireConnectedSpeakers() throws {
        guard !speakers.isEmpty else { throw EngineError.cancelled }
        let missing = missingSpeakerNames()
        if !missing.isEmpty {
            throw EngineError.speakersDisconnected(SpeakerNames.list(missing))
        }
    }

    func calibrate(progress: (String, String) async -> Void) async throws -> Calibration {
        while !measuring.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged {
            try await Task.sleep(for: .milliseconds(200))
        }
        defer { measuring.store(false, ordering: .releasing) }
        guard speakers.count >= 2 else { throw EngineError.cancelled }
        try requireConnectedSpeakers()
        let names = SpeakerNames.list(speakers.map(\.name))
        await progress(
            "Checking speakers",
            "\(names) are connected."
        )
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        defer {
            microphone.stop()
            self.microphone = nil
            for speaker in speakers {
                speaker.output.resume()
            }
        }
        var results: [(latency: Double, shape: BandLevel)] = []
        for index in speakers.indices {
            let name = speakers[index].name
            await progress(
                "Testing \(name)",
                "Playing a sweep through \(name). The Mac microphone is listening for delay and tone. That speaker is turned up for the test, then put back."
            )
            let others = speakers.enumerated().filter { $0.offset != index }.map(\.element.output)
            let result = try await measure(speaker: speakers[index].output, others: others, microphone: microphone, name: name)
            results.append(result)
        }
        await progress(
            "Comparing speakers",
            "Setting the delay, and sending each part of the sound to the speaker that reproduces it better."
        )
        let slowest = results.map(\.latency).max() ?? 0
        let cuts = ToneSplit.cuts(for: results.map(\.shape))
        var measured: [SpeakerMeasurement] = []
        for index in speakers.indices {
            let delay = max(0, slowest - results[index].latency)
            speakers[index].delay = delay
            speakers[index].cut = cuts[index]
            speakers[index].output.reader.setDelay(delay)
            speakers[index].output.setTone(toneEnabled ? cuts[index] : .flat)
            if let wantedIndex = wanted.firstIndex(where: { $0.id == speakers[index].id }) {
                wanted[wantedIndex].delay = delay
                wanted[wantedIndex].cut = cuts[index]
            }
            measured.append(SpeakerMeasurement(
                id: speakers[index].id,
                name: speakers[index].name,
                delay: delay,
                cut: cuts[index]
            ))
        }
        silenceRecheckEnabled = true
        return Calibration(speakers: measured)
    }

    private func measure(
        speaker: SpeakerOutput,
        others: [SpeakerOutput],
        microphone: MicrophoneRecorder,
        name: String
    ) async throws -> (latency: Double, shape: BandLevel) {
        microphone.stop()
        try microphone.start()
        try await Task.sleep(for: .milliseconds(100))
        for other in others {
            other.silence()
        }
        let savedLevel = DeviceLevel.boost(speaker.device.id)
        defer { DeviceLevel.restore(speaker.device.id, savedLevel) }
        let playback = Chirp.make(sampleRate: speaker.sampleRate)
        speaker.playChirp(playback)
        let host = try await waitForHostTime(on: speaker)
        let listen = Chirp.duration + 0.9
        try await Task.sleep(for: .milliseconds(Int(listen * 1_000)))
        speaker.silence()
        for other in others {
            other.silence()
        }

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

    private func waitForSpeakers(_ setups: [SpeakerSetup]) async throws -> [AudioDeviceInfo] {
        let names = setups.map(\.name)
        for _ in 0..<24 {
            if let match = AudioDevices.matchBluetooth(names: names) {
                return match
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        let present = AudioDevices.bluetoothOutputs()
        let missing = names.filter { name in
            !present.contains { SpeakerNames.match($0.name, name) }
        }
        let seen = AudioDevices.outputs().map(\.name).joined(separator: ", ")
        throw EngineError.speakersMissing(
            SpeakerNames.list(missing.isEmpty ? names : missing),
            seen.isEmpty ? "none" : seen
        )
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
        for speaker in speakers {
            speaker.output.reader.setGain(speaker.trim * master)
        }
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
        let outputs = AudioDevices.bluetoothOutputs()
        return speakers.compactMap { speaker in
            outputs.contains { $0.uid == speaker.output.device.uid } ? nil : speaker.name
        }
    }

    private func recoverDisconnectedSpeakers() async -> Bool {
        let missing = missingSpeakerNames()
        guard !missing.isEmpty else { return false }
        for name in missing where !reportedMissing.contains(name) {
            reportedMissing.insert(name)
            onNotice?(.speakerLost(name))
        }
        let setups = wanted
        try? await Task.detached(priority: .userInitiated) {
            try BluetoothSpeakers.connect(setups)
        }.value
        for _ in 0..<12 {
            guard let match = AudioDevices.matchBluetooth(names: setups.map(\.name)) else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            var restored = false
            for (setup, device) in zip(setups, match) {
                guard missing.contains(setup.name) else { continue }
                guard adopt(device, id: setup.id) else { continue }
                reportedMissing.remove(setup.name)
                onNotice?(.speakerBack(setup.name))
                restored = true
            }
            return restored
        }
        return false
    }

    private func adopt(_ info: AudioDeviceInfo, id: String) -> Bool {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return false }
        if speakers[index].output.device.uid == info.uid { return true }
        speakers[index].output.stop()
        let output = SpeakerOutput(device: info, clock: clock)
        do {
            try output.start()
        } catch {
            return false
        }
        let delay = speakers[index].delay
        let cut = speakers[index].cut
        output.reader.setDelay(delay)
        output.setTone(toneEnabled ? cut : .flat)
        speakers[index].output = output
        applyGains()
        return true
    }

    private func recheckDelay() async {
        guard speakers.count >= 2 else { return }
        onNotice?(.rechecking)
        let microphone = MicrophoneRecorder()
        self.microphone = microphone
        defer {
            microphone.stop()
            self.microphone = nil
            for speaker in speakers {
                speaker.output.resume()
            }
        }
        do {
            var latencies: [Double] = []
            for index in speakers.indices {
                let others = speakers.enumerated().filter { $0.offset != index }.map(\.element.output)
                let result = try await measure(
                    speaker: speakers[index].output,
                    others: others,
                    microphone: microphone,
                    name: speakers[index].name
                )
                latencies.append(result.latency)
            }
            let slowest = latencies.max() ?? 0
            var updates: [(id: String, delay: Double)] = []
            for index in speakers.indices {
                let delay = max(0, slowest - latencies[index])
                speakers[index].delay = delay
                speakers[index].output.reader.setDelay(delay)
                if let wantedIndex = wanted.firstIndex(where: { $0.id == speakers[index].id }) {
                    wanted[wantedIndex].delay = delay
                }
                updates.append((speakers[index].id, delay))
            }
            onNotice?(.delaysUpdated(updates))
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
    static let speakerRecords = "speakerRecords"
}

struct SpeakerMeasurement {
    var id: String
    var name: String
    var delay: Double
    var cut: BandCut
}

struct Calibration {
    var speakers: [SpeakerMeasurement]
}

enum EngineNotice {
    case rechecking
    case delaysUpdated([(id: String, delay: Double)])
    case recheckFailed(String)
    case speakerLost(String)
    case speakerBack(String)
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
