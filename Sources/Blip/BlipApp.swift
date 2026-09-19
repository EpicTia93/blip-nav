import AppKit

/// Agent app entry point.
///
/// `Info.plist` sets `LSUIElement`, so there is no Dock icon and no main menu; the
/// status bar item and the overlay panels are the whole UI. `main.swift` would put this
/// in a nonisolated top-level context, so it lives in a `@MainActor` type instead.
@main
@MainActor
enum BlipApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        // Keeps the delegate alive for the process's lifetime.
        withExtendedLifetime(delegate) {}
    }
}
