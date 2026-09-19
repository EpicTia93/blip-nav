import BlipKit
import Foundation
import SwiftUI

/// Polls the TCC grants.
///
/// Polling rather than observing because macOS posts no notification when a permission
/// is granted: the user leaves for System Settings, flips a switch, and the only way to
/// notice is to keep asking. One second is frequent enough to feel live when they come
/// back, and costs nothing.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var hasAccessibility = Permissions.hasAccessibility
    @Published private(set) var hasScreenRecording = Permissions.hasScreenRecording

    /// Fires when Accessibility flips from denied to granted, so the event tap can be
    /// started without the user having to relaunch.
    var onAccessibilityGranted: (() -> Void)?

    private var timer: Timer?

    func start(interval: TimeInterval = 1.0) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let accessibility = Permissions.hasAccessibility
        let screenRecording = Permissions.hasScreenRecording

        let wasDenied = !hasAccessibility
        if hasAccessibility != accessibility { hasAccessibility = accessibility }
        if hasScreenRecording != screenRecording { hasScreenRecording = screenRecording }
        if wasDenied, accessibility { onAccessibilityGranted?() }
    }
}
