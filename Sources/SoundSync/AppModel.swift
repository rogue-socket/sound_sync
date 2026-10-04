import AppKit
import AVFoundation
import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var isOn = false
    @Published var isBusy = false
    @Published var isCalibrating = false
    @Published var status = "Off"
    @Published var detail = "Sync is measured at the Mac. Put the laptop where you are listening, in a quiet room."
    @Published var speakers: [SpeakerRecord] = []
    @Published var available: [DiscoveredSpeaker] = []
    @Published var macVolume: Double = 1
    @Published var toneEnabled: Bool
    @Published var toneMeasured: Bool

    private let engine = Engine()
    private var run: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Store.toneEnabled) == nil {
            toneEnabled = true
        } else {
            toneEnabled = defaults.bool(forKey: Store.toneEnabled)
        }
        toneMeasured = defaults.bool(forKey: Store.toneMeasured)
        speakers = SpeakerLibrary.load()
        available = SpeakerLibrary.available(excluding: speakers)
        OutputRestore.recoverIfNeeded()
        engine.onMasterVolume = { value in
            Task { @MainActor in
                self.macVolume = Double(value)
            }
        }
        engine.onNotice = { notice in
            Task { @MainActor in
                self.handle(notice)
            }
        }
    }

    func toggle() {
        if isOn {
            turnOff()
        } else {
            turnOn()
        }
    }

    func refreshSpeakers() {
        guard !isOn, !isBusy, !isCalibrating else { return }
        speakers = SpeakerLibrary.applyingDiscovery(speakers)
        available = SpeakerLibrary.available(excluding: speakers)
        SpeakerLibrary.save(speakers)
    }

    func addSpeaker(_ device: DiscoveredSpeaker) {
        guard !isOn, !isBusy, !isCalibrating else { return }
        guard !speakers.contains(where: { $0.id == device.id || SpeakerNames.match($0.name, device.name) }) else { return }
        speakers.append(SpeakerRecord(
            id: device.id,
            name: device.name,
            address: device.address,
            included: true,
            volume: 0.8,
            delay: 0,
            lowDB: 0,
            midDB: 0,
            highDB: 0,
            available: device.connected
        ))
        available.removeAll { $0.id == device.id || SpeakerNames.match($0.name, device.name) }
        SpeakerLibrary.save(speakers)
    }

    func removeSpeaker(_ id: String) {
        guard !isOn, !isBusy, !isCalibrating else { return }
        speakers.removeAll { $0.id == id }
        available = SpeakerLibrary.available(excluding: speakers)
        SpeakerLibrary.save(speakers)
    }

    func setVolume(_ id: String, _ value: Double) {
        guard let index = speakers.firstIndex(where: { $0.id == id }) else { return }
        speakers[index].volume = value
        SpeakerLibrary.save(speakers)
        engine.setGain(id: id, gain: Float(value))
    }

    func setToneEnabled(_ enabled: Bool) {
        toneEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Store.toneEnabled)
        engine.setToneEnabled(enabled)
    }

    func calibrate() {
        guard isOn, !isCalibrating else { return }
        isCalibrating = true
        status = "Checking speakers"
        detail = "Looking for the speakers you added."
        Task {
            do {
                try engine.requireConnectedSpeakers()
            } catch {
                status = "Speakers not connected"
                detail = error.localizedDescription
                isCalibrating = false
                return
            }
            let allowed = await Self.microphoneAllowed()
            guard allowed else {
                status = "Microphone access is off"
                detail = "Allow Sound Sync to use the microphone in System Settings, then calibrate again."
                isCalibrating = false
                return
            }
            do {
                let result = try await engine.calibrate { title, detail in
                    await MainActor.run {
                        self.status = title
                        self.detail = detail
                    }
                }
                for measurement in result.speakers {
                    guard let index = speakers.firstIndex(where: { $0.id == measurement.id }) else { continue }
                    speakers[index].delay = measurement.delay
                    speakers[index].lowDB = measurement.cut.lowDB
                    speakers[index].midDB = measurement.cut.midDB
                    speakers[index].highDB = measurement.cut.highDB
                }
                toneMeasured = true
                UserDefaults.standard.set(true, forKey: Store.toneMeasured)
                SpeakerLibrary.save(speakers)
                status = "On"
                detail = statusText()
            } catch {
                status = "Calibration failed"
                detail = error.localizedDescription
            }
            isCalibrating = false
        }
    }

    func turnOff() {
        run?.cancel()
        engine.stop()
        isOn = false
        isBusy = false
        isCalibrating = false
        status = "Off"
        detail = "Sync is measured at the Mac. Put the laptop where you are listening, in a quiet room."
    }

    private func turnOn() {
        guard !isBusy else { return }
        let chosen = speakers.filter(\.included)
        guard chosen.count >= 2 else {
            status = "Pick speakers"
            detail = "Check at least two speakers. Sync needs more than one."
            return
        }
        isBusy = true
        status = "Connecting speakers…"
        detail = "Turn on \(SpeakerNames.list(chosen.map(\.name)))."
        let recheck = toneMeasured || chosen.contains { $0.delay != 0 }
        let setups = chosen.map { $0.setup() }
        run = Task {
            do {
                try await engine.start(setups, toneEnabled: toneEnabled, silenceRecheck: recheck)
                isOn = true
                isBusy = false
                status = "On"
                detail = statusText()
            } catch {
                engine.stop()
                isOn = false
                isBusy = false
                status = "Couldn't start"
                detail = error.localizedDescription
            }
        }
    }

    private func statusText() -> String {
        let chosen = speakers.filter(\.included)
        var text = Self.delayText(chosen)
        if toneMeasured {
            let summary = ToneSplit.summary(names: chosen.map(\.name), cuts: chosen.map(\.cut))
            if !summary.isEmpty {
                text += " " + summary
            }
        }
        return text
    }

    private static func delayText(_ speakers: [SpeakerRecord]) -> String {
        let delays = speakers.map { ($0.name, Int(($0.delay * 1000).rounded())) }
        if delays.allSatisfy({ $0.1 == 0 }) {
            return "Not calibrated yet. Press Calibrate while the room is quiet."
        }
        let anchors = delays.filter { $0.1 == 0 }.map(\.0)
        let delayed = delays.filter { $0.1 > 0 }.map { "\($0.0) by \($0.1) ms" }
        let anchor: String
        if anchors.count == 1 {
            anchor = anchors[0]
        } else if anchors.isEmpty {
            anchor = "the slowest speaker"
        } else {
            anchor = "the others"
        }
        let verb = delayed.count == 1 ? "it matches" : "they match"
        return "Delaying \(SpeakerNames.list(delayed)) so \(verb) \(anchor)."
    }

    private func handle(_ notice: EngineNotice) {
        guard !isCalibrating else { return }
        switch notice {
        case .rechecking:
            status = "Rechecking delay"
            detail = "Playback is quiet, so Sound Sync is measuring the speakers again."
        case .delaysUpdated(let updates):
            for update in updates {
                guard let index = speakers.firstIndex(where: { $0.id == update.id }) else { continue }
                speakers[index].delay = update.delay
            }
            SpeakerLibrary.save(speakers)
            status = "On"
            detail = statusText()
        case .recheckFailed(let message):
            status = "Delay check failed"
            detail = message
        case .speakerLost(let name):
            status = "\(name) disconnected"
            detail = "Trying to reconnect. Calibrate again after it comes back."
        case .speakerBack(let name):
            status = "\(name) reconnected"
            detail = "Press Calibrate so the delay matches this connection."
        }
    }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { allowed in
                    continuation.resume(returning: allowed)
                }
            }
        default:
            return false
        }
    }
}

struct ControlView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Sound Sync")
                        .font(.headline)
                    Spacer()
                    Toggle("On", isOn: Binding(
                        get: { model.isOn },
                        set: { _ in model.toggle() }
                    ))
                    .labelsHidden()
                    .disabled(model.isBusy || model.isCalibrating)
                }

                Text(model.status)
                    .font(.subheadline.weight(.semibold))
                Text(model.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.isOn {
                    Text(model.macVolume == 0
                        ? "Mac volume is muted. The volume keys control every speaker."
                        : "Mac volume \(Int((model.macVolume * 100).rounded()))%. The volume keys control every speaker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Speakers")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Menu("Add speaker") {
                        if model.available.isEmpty {
                            Button("No other Bluetooth devices") {}
                                .disabled(true)
                        } else {
                            ForEach(model.available) { device in
                                Button(device.connected ? device.name : "\(device.name) — not connected") {
                                    model.addSpeaker(device)
                                }
                            }
                        }
                    }
                    .disabled(model.isOn || model.isBusy || model.isCalibrating)
                    Button("Refresh") {
                        model.refreshSpeakers()
                    }
                    .disabled(model.isOn || model.isBusy || model.isCalibrating)
                }

                Text(model.isOn
                    ? "Turn Sound Sync off to add or remove speakers."
                    : "Add speakers from the Bluetooth devices that are paired or connected. At least two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.speakers.isEmpty {
                    Text("No speakers added yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.speakers) { speaker in
                        speakerRow(speaker)
                    }
                }

                if model.toneMeasured {
                    Toggle("Tone split", isOn: Binding(
                        get: { model.toneEnabled },
                        set: { model.setToneEnabled($0) }
                    ))
                    .disabled(!model.isOn || model.isCalibrating)
                    ForEach(model.speakers.filter(\.included)) { speaker in
                        Text(Self.cutsLine(speaker.name, speaker.cut))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Button(model.isCalibrating ? "Calibrating…" : "Calibrate") {
                    model.calibrate()
                }
                .disabled(!model.isOn || model.isCalibrating)

                Button("Quit") {
                    model.turnOff()
                    NSApp.terminate(nil)
                }
            }
            .padding(16)
        }
        .frame(width: 380)
    }

    private func speakerRow(_ speaker: SpeakerRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.name)
                    if !speaker.available {
                        Text("Not connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Remove") {
                    model.removeSpeaker(speaker.id)
                }
                .disabled(model.isOn || model.isBusy || model.isCalibrating)
            }
            HStack {
                Text("Volume")
                Spacer()
                Text("\(Int((speaker.volume * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption)
            Slider(
                value: Binding(
                    get: { speaker.volume },
                    set: { model.setVolume(speaker.id, $0) }
                ),
                in: 0...1
            )
        }
    }

    private static func cutsLine(_ name: String, _ cut: BandCut) -> String {
        "\(name)  lows \(decibels(cut.lowDB))  mids \(decibels(cut.midDB))  highs \(decibels(cut.highDB))"
    }

    private static func decibels(_ value: Float) -> String {
        "\(Int(value.rounded())) dB"
    }
}

@MainActor
final class StatusBarController: NSObject {
    private let model: AppModel
    private var item: NSStatusItem?
    private var window: NSWindow?
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init()
        installStatusItem()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "SoundSyncStatus"
        item.isVisible = true
        self.item = item

        if let button = item.button {
            button.title = "Sync"
            button.image = Self.menuImage()
            button.imagePosition = .imageLeading
            button.action = #selector(showWindow)
            button.target = self
        } else {
            return
        }
    }

    @objc func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: ControlView(model: model))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Sound Sync"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 380, height: 560))
            self.window = window
        }
        if let window {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
                ?? NSScreen.main
                ?? NSScreen.screens.first
            if let screen {
                let visible = screen.visibleFrame
                let size = window.frame.size
                window.setFrameOrigin(NSPoint(
                    x: visible.midX - size.width / 2,
                    y: visible.midY - size.height / 2
                ))
            }
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func menuImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Sound Sync") ?? NSImage()
    }

    private func updateIcon() {
        item?.button?.image = Self.menuImage()
    }
}
