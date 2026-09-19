import AppKit
import BlipCore
import BlipKit
import SwiftUI

/// Drives one activation from trigger to click.
///
/// Sequence: swallow the keyboard, put empty panels up immediately, fill them from the
/// Accessibility pass (tens of milliseconds), then append the OCR pass when it lands.
/// Showing the panels before the scan finishes is deliberate -- it makes the trigger
/// feel instant, and the dimming alone confirms Blip heard the keystroke.
@MainActor
final class SessionController {

    private let state = OverlayState()
    private let settings: SettingsStore
    private let tap: TriggerTap

    private var panels: [OverlayPanel] = []
    private var scanTask: Task<Void, Never>?
    private var prefixTimeoutTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?

    /// Safety valve. While a session is open the event tap swallows every keystroke,
    /// so a session that somehow fails to end would leave the keyboard unusable with no
    /// obvious way out. Nothing should ever reach this, which is exactly why it is here.
    private static let idleTimeout: Duration = .seconds(15)

    private(set) var isActive = false

    /// Called when a session cannot start because a permission is missing.
    var onPermissionNeeded: (() -> Void)?

    init(settings: SettingsStore) {
        self.settings = settings
        tap = TriggerTap(configuration: settings.configuration)

        tap.onTrigger = { [weak self] in self?.toggle() }
        tap.onKey = { [weak self] press in self?.handle(press) }
    }

    var configuration: Configuration { settings.configuration }

    func startListening() throws {
        try tap.start()
    }

    func stopListening() {
        tap.stop()
    }

    /// Picks up a changed trigger key or appearance without a relaunch.
    func configurationChanged() {
        tap.configuration = settings.configuration
    }

    // MARK: - Session lifecycle

    func toggle() {
        if isActive {
            dismiss()
        } else {
            begin()
        }
    }

    func begin() {
        guard !isActive else { return }
        guard Permissions.hasAccessibility else {
            onPermissionNeeded?()
            return
        }

        Log.session.notice("session begin")
        isActive = true
        state.reset()
        tap.beginCapture()
        showPanels()
        restartIdleTimeout()

        let configuration = settings.configuration
        scanTask = Task { [weak self] in
            guard let self else { return }

            let pass = await ScanCoordinator.accessibilityPass()
            guard self.isActive else { return }
            Log.session.notice("ax pass: \(pass.targets.count) targets in \(Int(pass.duration * 1000))ms\(pass.truncatedApps.isEmpty ? "" : "; truncated: " + pass.truncatedApps.joined(separator: ", "), privacy: .public)")
            self.state.setTargets(pass.targets)

            guard configuration.ocrEnabled else { return }
            guard Permissions.hasScreenRecording else {
                self.state.notice = "OCR off: no Screen Recording permission"
                return
            }

            self.state.isScanningOCR = true
            var ocrOptions = OCROptions()
            ocrOptions.languages = configuration.ocrLanguages
            let ocr = await ScanCoordinator.ocrPass(
                existing: pass.targets, options: ocrOptions
            )
            guard self.isActive else { return }
            self.state.isScanningOCR = false
            Log.session.notice("ocr pass: \(ocr.targets.count) new of \(ocr.rawCount) recognised in \(Int(ocr.duration * 1000))ms (capture \(Int(ocr.captureDuration * 1000))ms, recognise \(Int(ocr.recognizeDuration * 1000))ms)\(ocr.error.map { "; error: " + $0 } ?? "", privacy: .public)")
            self.state.appendTargets(ocr.targets)
        }
    }

    func dismiss() {
        guard isActive else { return }
        isActive = false
        scanTask?.cancel()
        scanTask = nil
        prefixTimeoutTask?.cancel()
        prefixTimeoutTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        tap.endCapture()
        hidePanels()
        state.reset()
    }

    // MARK: - Panels

    private func showPanels() {
        hidePanels()
        // Rebuilt every session rather than cached, so display changes, resolution
        // changes and a laptop being undocked all just work.
        let activeScreen = screenUnderMouse()

        for screen in NSScreen.screens {
            let bounds = ScreenInfo.cgBounds(of: screen)
            let panel = OverlayPanel(
                screen: screen,
                content: OverlayView(
                    state: state,
                    screenCGBounds: bounds,
                    showsSearchBar: screen == activeScreen,
                    configuration: settings.configuration
                )
            )
            // orderFrontRegardless, not makeKeyAndOrderFront: Blip must not activate.
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    private func hidePanels() {
        for panel in panels {
            panel.orderOut(nil)
            panel.close()
        }
        panels.removeAll()
    }

    private func screenUnderMouse() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    // MARK: - Keys

    private func handle(_ press: CapturedKey) {
        guard isActive else { return }
        restartIdleTimeout()

        // Any command- or control-chord is the user reaching past Blip. Get out of the
        // way rather than swallowing something they meant for the app underneath.
        if press.flags.contains(.maskCommand) || press.flags.contains(.maskControl) {
            dismiss()
            return
        }

        if press.isEscape {
            dismiss()
            return
        }

        if press.isReturn {
            if let target = state.topMatch { activate(target) } else { dismiss() }
            return
        }

        if press.isDelete {
            prefixTimeoutTask?.cancel()
            state.deleteBackward()
            return
        }

        guard let character = press.characters.first else { return }

        if character.isNumber {
            state.appendDigit(String(character))
            resolveDigits()
            return
        }

        if character.isLetter || character == " " || character == "-" || character == "." {
            state.appendQueryCharacter(String(character))
        }
    }

    /// Applies the Vimium prefix rule to whatever digits have been typed.
    private func resolveDigits() {
        prefixTimeoutTask?.cancel()

        switch state.resolveDigits() {
        case .exact(let id):
            if let target = state.target(id: id) { activate(target) }

        case .none:
            // Dead end: the digits cannot lead anywhere, so drop them rather than
            // leaving the user stuck typing into a prefix that will never resolve.
            state.clearDigitPrefix()

        case .pending(let exactMatch):
            guard let exactMatch else { return }
            // The prefix is a complete number but longer ones share it. Wait briefly
            // for another digit; if none comes, the user meant this one.
            let timeout = settings.configuration.hintPrefixTimeout
            prefixTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled, let self, self.isActive else { return }
                if let target = self.state.target(id: exactMatch) { self.activate(target) }
            }
        }
    }

    private func restartIdleTimeout() {
        idleTimeoutTask?.cancel()
        idleTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    // MARK: - Action

    private func activate(_ target: Target) {
        // Tear the overlay down first: the action should look instantaneous, and the
        // hints have already served their purpose.
        dismiss()
        Task {
            let outcome = await Actuator.activate(target)
            if case .failed(let reason) = outcome {
                NSLog("Blip: could not activate \(target.label): \(reason)")
            }
        }
    }
}
