import AppKit
import ApplicationServices
import CoreGraphics

/// The two TCC grants Blip needs, and the deep links that take a user straight to them.
///
/// Blip degrades rather than fails. Without Screen Recording it runs Accessibility-only
/// and says so; without Accessibility it can do nothing at all, since both the hotkey
/// tap and every scan depend on it.
public enum Permissions {

    // MARK: - Accessibility

    /// Required for: the CGEventTap that reads the trigger, reading other apps' AX
    /// trees, and pressing their controls.
    public static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system's "grant Accessibility" prompt. Only the first call per app
    /// signature actually presents UI; afterwards macOS silently ignores it, which is
    /// why `openAccessibilitySettings()` exists as the follow-up.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    /// Required for OCR: ScreenCaptureKit cannot hand back pixels without it.
    public static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Settings deep links

    public static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    public static func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Summary

    public struct Snapshot: Equatable, Sendable {
        public var accessibility: Bool
        public var screenRecording: Bool

        /// Accessibility is the hard requirement; nothing works without it.
        public var canRun: Bool { accessibility }
        /// OCR is optional, so its absence only narrows what Blip can see.
        public var canOCR: Bool { screenRecording }
    }

    public static func snapshot() -> Snapshot {
        Snapshot(accessibility: hasAccessibility, screenRecording: hasScreenRecording)
    }
}
