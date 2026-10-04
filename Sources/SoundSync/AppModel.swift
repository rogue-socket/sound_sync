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
    @Published var pulseVolume: Double
    @Published var sonyVolume: Double
    @Published var macVolume: Double = 1
    @Published var toneEnabled: Bool
    @Published var pulseCut = BandCut.flat
    @Published var sonyCut = BandCut.flat

    private let engine = Engine()
    private var run: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        pulseVolume = defaults.object(forKey: Store.pulseVolume) as? Double ?? 0.8
        sonyVolume = defaults.object(forKey: Store.sonyVolume) as? Double ?? 1.0
        if defaults.object(forKey: Store.toneEnabled) == nil {
            toneEnabled = true
        } else {
            toneEnabled = defaults.bool(forKey: Store.toneEnabled)
        }
        pulseCut = Self.storedCut(prefix: "pulse")
        sonyCut = Self.storedCut(prefix: "sony")
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

    func setPulseVolume(_ value: Double) {
        pulseVolume = value
        UserDefaults.standard.set(value, forKey: Store.pulseVolume)
        engine.setGains(pulse: Float(value), sony: Float(sonyVolume))
    }

    func setSonyVolume(_ value: Double) {
        sonyVolume = value
        UserDefaults.standard.set(value, forKey: Store.sonyVolume)
        engine.setGains(pulse: Float(pulseVolume), sony: Float(value))
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
        detail = "Looking for the Pulse 4 and the SRS-XB13."
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
                Self.store(result.pulseCut, prefix: "pulse")
                Self.store(result.sonyCut, prefix: "sony")
                pulseCut = result.pulseCut
                sonyCut = result.sonyCut
                UserDefaults.standard.set(true, forKey: Store.toneMeasured)
                UserDefaults.standard.set(result.pulseDelay, forKey: Store.pulseDelay)
                UserDefaults.standard.set(result.sonyDelay, forKey: Store.sonyDelay)
                status = "On"
                detail = Self.statusText(
                    pulseDelay: result.pulseDelay,
                    sonyDelay: result.sonyDelay,
                    pulseCut: result.pulseCut,
                    sonyCut: result.sonyCut
                )
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
        isBusy = true
        status = "Connecting both speakers…"
        detail = "Turn the Pulse 4 and the SRS-XB13 on."
        let pulse = Float(pulseVolume)
        let sony = Float(sonyVolume)
        let pulseDelay = UserDefaults.standard.double(forKey: Store.pulseDelay)
        let sonyDelay = UserDefaults.standard.double(forKey: Store.sonyDelay)
        let pulseCut = Self.storedCut(prefix: "pulse")
        let sonyCut = Self.storedCut(prefix: "sony")
        let recheck = UserDefaults.standard.bool(forKey: Store.toneMeasured)
            || pulseDelay != 0
            || sonyDelay != 0
        run = Task {
            do {
                try await engine.start(
                    pulseGain: pulse,
                    sonyGain: sony,
                    pulseDelay: pulseDelay,
                    sonyDelay: sonyDelay,
                    pulseCut: pulseCut,
                    sonyCut: sonyCut,
                    toneEnabled: toneEnabled,
                    silenceRecheck: recheck
                )
                isOn = true
                isBusy = false
                status = "On"
                detail = Self.statusText(pulseDelay: pulseDelay, sonyDelay: sonyDelay, pulseCut: pulseCut, sonyCut: sonyCut)
            } catch {
                engine.stop()
                isOn = false
                isBusy = false
                status = "Couldn't start"
                detail = error.localizedDescription
            }
        }
    }

    private static func statusText(pulseDelay: Double, sonyDelay: Double, pulseCut: BandCut, sonyCut: BandCut) -> String {
        var text = delayText(pulse: pulseDelay, sony: sonyDelay)
        if UserDefaults.standard.bool(forKey: Store.toneMeasured) {
            text += " " + ToneSplit.summary(pulse: pulseCut, sony: sonyCut)
        }
        return text
    }

    private static func storedCut(prefix: String) -> BandCut {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Store.toneMeasured) else { return .flat }
        return BandCut(
            lowDB: Float(defaults.double(forKey: "\(prefix)LowDB")),
            midDB: Float(defaults.double(forKey: "\(prefix)MidDB")),
            highDB: Float(defaults.double(forKey: "\(prefix)HighDB"))
        )
    }

    private static func store(_ cut: BandCut, prefix: String) {
        let defaults = UserDefaults.standard
        defaults.set(Double(cut.lowDB), forKey: "\(prefix)LowDB")
        defaults.set(Double(cut.midDB), forKey: "\(prefix)MidDB")
        defaults.set(Double(cut.highDB), forKey: "\(prefix)HighDB")
    }

    private static func delayText(pulse: Double, sony: Double) -> String {
        let pulseMs = Int((pulse * 1000).rounded())
        let sonyMs = Int((sony * 1000).rounded())
        if pulseMs == 0 && sonyMs == 0 {
            return "Not calibrated yet. Press Calibrate while the room is quiet."
        }
        if pulseMs >= sonyMs {
            return "Delaying the Pulse 4 by \(pulseMs) ms so it matches the SRS-XB13."
        }
        return "Delaying the SRS-XB13 by \(sonyMs) ms so it matches the Pulse 4."
    }

    private func handle(_ notice: EngineNotice) {
        guard !isCalibrating else { return }
        switch notice {
        case .rechecking:
            status = "Rechecking delay"
            detail = "Playback is quiet, so Sound Sync is measuring both speakers again."
        case .delaysUpdated(let pulseDelay, let sonyDelay):
            UserDefaults.standard.set(pulseDelay, forKey: Store.pulseDelay)
            UserDefaults.standard.set(sonyDelay, forKey: Store.sonyDelay)
            status = "On"
            detail = Self.statusText(pulseDelay: pulseDelay, sonyDelay: sonyDelay, pulseCut: pulseCut, sonyCut: sonyCut)
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
                    ? "Mac volume is muted. The volume keys control both speakers."
                    : "Mac volume \(Int((model.macVolume * 100).rounded()))%. The volume keys control both speakers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            volume("JBL Pulse 4", value: model.pulseVolume, set: model.setPulseVolume)
            volume("Sony SRS-XB13", value: model.sonyVolume, set: model.setSonyVolume)

            if UserDefaults.standard.bool(forKey: Store.toneMeasured) {
                Toggle("Tone split", isOn: Binding(
                    get: { model.toneEnabled },
                    set: { model.setToneEnabled($0) }
                ))
                .disabled(!model.isOn || model.isCalibrating)
                Text(Self.cutsLine("Pulse 4", model.pulseCut))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(Self.cutsLine("SRS-XB13", model.sonyCut))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
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
        .frame(width: 360)
    }

    private static func cutsLine(_ name: String, _ cut: BandCut) -> String {
        "\(name)  lows \(Self.decibels(cut.lowDB))  mids \(Self.decibels(cut.midDB))  highs \(Self.decibels(cut.highDB))"
    }

    private static func decibels(_ value: Float) -> String {
        let rounded = Int(value.rounded())
        return "\(rounded) dB"
    }

    private func volume(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            Slider(value: Binding(get: { value }, set: set), in: 0...1)
        }
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
        showWindow()
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
            button.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "Sound Sync")
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
            window.setContentSize(NSSize(width: 360, height: 420))
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
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateIcon() {
        let name = model.isOn ? "speaker.wave.2.fill" : "speaker.wave.2"
        item?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Sound Sync")
    }
}
