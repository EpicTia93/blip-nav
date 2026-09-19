import AppKit
import BlipKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let settings = SettingsStore()
    private let permissions = PermissionMonitor()
    private var session: SessionController!
    private var menuBar: MenuBarController!
    private var settingsWindow: NSWindow?
    private var settingsObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.notice("launching; accessibility=\(Permissions.hasAccessibility) screenRecording=\(Permissions.hasScreenRecording)")
        session = SessionController(settings: settings)
        menuBar = MenuBarController(settings: settings, permissions: permissions)

        menuBar.onActivate = { [weak self] in self?.session.begin() }
        menuBar.onOpenSettings = { [weak self] in self?.showSettings() }
        session.onPermissionNeeded = { [weak self] in self?.showSettings() }

        // Start the tap the moment Accessibility is granted, so a first-run user does
        // not have to relaunch after flipping the switch.
        permissions.onAccessibilityGranted = { [weak self] in
            self?.startListening()
            self?.menuBar.refresh()
        }
        permissions.start()

        // Trigger key and appearance changes take effect immediately.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: SettingsStore.didChangeNotification,
            object: settings,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.session.configurationChanged()
                self?.menuBar.refresh()
            }
        }

        if Permissions.hasAccessibility {
            startListening()
            warmUpAccessibility()
        } else {
            // Nothing works without this, so say so immediately rather than letting the
            // trigger silently do nothing.
            Permissions.requestAccessibility()
            showSettings()
        }
        menuBar.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stopListening()
        permissions.stop()
    }

    /// Runs one throwaway scan in the background shortly after launch.
    ///
    /// The first AX call to any given process pays for setting up its connection --
    /// around 240ms across a full desktop, against 15ms once those connections exist.
    /// Without this the user's very first trigger is the slowest one they will ever
    /// see, which is precisely the wrong first impression.
    private func warmUpAccessibility() {
        Task.detached(priority: .utility) {
            let started = Date()
            let pass = await ScanCoordinator.accessibilityPass()
            Log.app.notice("warm-up scan: \(pass.targets.count) targets in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
    }

    private func startListening() {
        do {
            try session.startListening()
        } catch {
            Log.app.error("could not start the event tap: \(String(describing: error), privacy: .public)")
        }
    }

    private func showSettings() {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(settings: settings, permissions: permissions)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Blip Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
