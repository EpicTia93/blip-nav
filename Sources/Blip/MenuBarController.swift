import AppKit
import BlipKit
import SwiftUI

/// The status bar item: Blip's only persistent UI, since it is an agent app with no
/// Dock icon and no windows of its own.
@MainActor
final class MenuBarController {

    private let statusItem: NSStatusItem
    private let settings: SettingsStore
    private let permissions: PermissionMonitor

    var onActivate: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    init(settings: SettingsStore, permissions: PermissionMonitor) {
        self.settings = settings
        self.permissions = permissions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        rebuildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(granted: true)
    }

    /// The menu bar icon.
    ///
    /// Loaded from the bundled white dolphin silhouette and marked as a template, so
    /// AppKit tints it for the light or dark menu bar rather than leaving a white blob
    /// on a light background. Falls back to an SF Symbol if the resource is missing,
    /// which is what happens when the binary is run outside its .app bundle.
    private static func statusImage(granted: Bool) -> NSImage? {
        guard granted else {
            let image = NSImage(
                systemSymbolName: "exclamationmark.triangle",
                accessibilityDescription: "Blip: permission required"
            )
            image?.isTemplate = true
            return image
        }

        if let url = Bundle.main.url(forResource: "StatusItem", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // Menu bar items are 22pt tall; the artwork is wider than it is tall, so
            // height is what gets constrained and the width follows.
            let height: CGFloat = 17
            let scale = height / image.size.height
            image.size = NSSize(width: image.size.width * scale, height: height)
            image.isTemplate = true
            return image
        }

        let fallback = NSImage(systemSymbolName: "scope", accessibilityDescription: "Blip")
        fallback?.isTemplate = true
        return fallback
    }

    /// Reflects permission state in the icon, so a broken install is visible at a
    /// glance rather than only when the trigger mysteriously does nothing.
    func refresh() {
        guard let button = statusItem.button else { return }
        button.image = Self.statusImage(granted: permissions.hasAccessibility)
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let trigger = settings.configuration.trigger
        let activate = NSMenuItem(
            title: "Show Hints  (\(trigger.menuDescription))",
            action: #selector(activateAction),
            keyEquivalent: ""
        )
        activate.target = self
        activate.isEnabled = permissions.hasAccessibility
        menu.addItem(activate)

        menu.addItem(.separator())

        if !permissions.hasAccessibility {
            menu.addItem(status("Accessibility not granted \u{2014} Blip cannot run"))
        }
        if !permissions.hasScreenRecording {
            menu.addItem(status("Screen Recording not granted \u{2014} OCR disabled"))
        }
        if permissions.hasAccessibility, permissions.hasScreenRecording {
            menu.addItem(status("Accessibility and OCR ready"))
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings\u{2026}", action: #selector(settingsAction), keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quit = NSMenuItem(
            title: "Quit Blip", action: #selector(quitAction), keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func status(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func activateAction() { onActivate?() }
    @objc private func settingsAction() { onOpenSettings?() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
