import AppKit
import SwiftUI

/// A full-screen, click-through, never-focused window that draws the hints.
///
/// The configuration here is load-bearing rather than cosmetic. If this panel ever
/// becomes key, Blip's own process becomes frontmost, the app the user was aiming at
/// stops being frontmost, and both `AXPress` and synthetic clicks start behaving
/// differently. So the panel must never accept focus -- which is also why the search
/// field is drawn text rather than a real `NSTextField`, and why keystrokes arrive
/// from the event tap instead of the responder chain.
final class OverlayPanel: NSPanel {

    init(screen: NSScreen, content: some View) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [
            .canJoinAllSpaces,      // follow the user across Spaces
            .fullScreenAuxiliary,   // appear over full-screen apps
            .stationary,            // do not slide during Mission Control
            .ignoresCycle,          // stay out of Cmd-Tab and window cycling
        ]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Purely a heads-up display: every click belongs to the app underneath.
        ignoresMouseEvents = true
        // Deliberately left capturable (`sharingType` untouched). Blip's own OCR pass
        // already excludes this process via SCContentFilter's `excludingApplications`,
        // which is the targeted fix; setting `.none` here would also stop the user
        // screenshotting or screen-sharing the hints, which is a thing people do.

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.frame = CGRect(origin: .zero, size: screen.frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(content: some View) {
        (contentView as? NSHostingView<AnyView>)?.rootView = AnyView(content)
    }
}
