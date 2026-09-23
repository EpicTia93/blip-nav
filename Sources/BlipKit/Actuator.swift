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
///    targets, the fallback when an element advertises no press action or its
///    press returns an error, and the first choice for web content (see below).
public enum Actuator {

    /// How long to let a raised window come forward before clicking into it. A
    /// synthetic click posted too early lands on whatever was in front a moment ago.
    public static let raiseSettleDelay: Duration = .milliseconds(60)

    /// Gap between the synthetic move, down and up events, so the target app sees
    /// them as a hover followed by a click rather than one indistinguishable burst.
    public static let clickStepDelay: Duration = .milliseconds(15)

    public enum Outcome: Sendable, Equatable {
        case pressed
        case clicked
        case failed(String)
    }

    @discardableResult
    public static func activate(_ target: Target) async -> Outcome {
        await bringForwardIfNeeded(target)

        // Web content gets a real click instead of AXPress. Chromium and WebKit accept
        // AXPress on anything with a click handler and report success, but only fire a
        // bare `click` event: no pointerdown/mousedown, which is what React and Radix
        // style controls actually listen for. The press "succeeds" and nothing happens.
        if let element = target.handle as? AXElement, element.supportsPress,
           !element.isInWebArea {
            let error = element.press()
            if error == .success { return .pressed }
            // Fall through: some controls list AXPress but reject it, notably web
            // content that has been re-rendered since the scan.
        }

        return await click(at: target.center)
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
    ///
    /// The events are spaced out and carry a click count: browsers drop a mouse-down
    /// with a click count of 0 from click dispatch, and a down/up pair arriving in the
    /// same instant as the move can be processed before hover state has settled.
    @discardableResult
    public static func click(at point: CGPoint) async -> Outcome {
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
            if type != .mouseMoved {
                event.setIntegerValueField(.mouseEventClickState, value: 1)
            }
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: clickStepDelay)
        }

        if let previousLocation {
            CGWarpMouseCursorPosition(previousLocation)
        }
        return .clicked
    }
}
