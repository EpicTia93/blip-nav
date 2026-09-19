import AppKit
import ApplicationServices
import BlipCore
import CoreGraphics
import Foundation

/// Carries out the action on a chosen target.
///
/// Two paths, in order of preference:
///
/// 1. `AXPress` on the element. Precise, synchronous, and independent of where the
///    mouse happens to be or what is drawn on top.
/// 2. A synthesised mouse click at the target's centre. The only option for OCR
///    targets, and the fallback when an element advertises no press action or its
///    press returns an error.
public enum Actuator {

    /// How long to let a raised window come forward before clicking into it. A
    /// synthetic click posted too early lands on whatever was in front a moment ago.
    public static let raiseSettleDelay: Duration = .milliseconds(60)

    public enum Outcome: Sendable, Equatable {
        case pressed
        case clicked
        case failed(String)
    }

    @discardableResult
    public static func activate(_ target: Target) async -> Outcome {
        await bringForwardIfNeeded(target)

        if let element = target.handle as? AXElement, element.supportsPress {
            let error = element.press()
            if error == .success { return .pressed }
            // Fall through: some controls list AXPress but reject it, notably web
            // content that has been re-rendered since the scan.
        }

        return click(at: target.center)
    }

    // MARK: - Focus

    /// Raises the target's app and window when it is not already frontmost.
    ///
    /// Scanning every app means most targets live in the background, where a synthetic
    /// click would otherwise hit whichever window is actually on top at that point.
    /// `AXPress` usually works without raising, but raising first also matches what a
    /// user expects to happen: the thing they picked comes forward.
    private static func bringForwardIfNeeded(_ target: Target) async {
        guard target.pid != 0 else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard target.pid != frontmostPID else { return }

        if let app = NSRunningApplication(processIdentifier: target.pid) {
            app.activate(options: [])
        }
        if let windowID = target.windowID,
           let window = axWindow(pid: target.pid, windowID: windowID) {
            window.raiseWindow()
        }
        try? await Task.sleep(for: raiseSettleDelay)
    }

    private static func axWindow(pid: pid_t, windowID: CGWindowID) -> AXElement? {
        let app = AXElement.application(pid: pid)
        app.setMessagingTimeout(0.2)
        return app.windows.first { $0.windowID == windowID }
    }

    // MARK: - Synthetic click

    /// Posts a left click at a CG-space point, restoring the pointer afterwards.
    ///
    /// The pointer is warped rather than left in place because many controls only
    /// respond to a click that arrives with the cursor genuinely over them, and some
    /// reveal hover state first. Restoring it afterwards keeps the click from
    /// disturbing whatever the user was pointing at.
    @discardableResult
    public static func click(at point: CGPoint) -> Outcome {
        let previousLocation = CGEvent(source: nil)?.location
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            return .failed("could not create event source")
        }
        // Suppress the local mouse-move coalescing that would otherwise swallow the
        // warp immediately preceding the click.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        CGWarpMouseCursorPosition(point)

        let events: [(CGEventType, CGMouseButton)] = [
            (.mouseMoved, .left),
            (.leftMouseDown, .left),
            (.leftMouseUp, .left),
        ]
        for (type, button) in events {
            guard let event = CGEvent(
                mouseEventSource: source,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: button
            ) else { return .failed("could not create \(type) event") }
            event.post(tap: .cghidEventTap)
        }

        if let previousLocation {
            CGWarpMouseCursorPosition(previousLocation)
        }
        return .clicked
    }
}
