import AppKit
import BlipKit
import SwiftUI

/// A field that records whatever the user presses and turns it into a `Trigger`.
///
/// This is AppKit rather than SwiftUI because of the double-tap case. SwiftUI's
/// `onKeyPress` never sees a modifier pressed on its own, and `onModifierKeysChanged`
/// reports only *which* modifier, not which side of the keyboard -- and the whole point
/// of the double-tap trigger is that Right Command is free while Left Command is not.
/// Only `NSView.flagsChanged`, which carries the physical key code, can tell them apart.
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var trigger: Trigger
    /// Recording uses the same window the tap will, so a gesture that records is by
    /// definition a gesture that fires.
    var doubleTapWindow: TimeInterval

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = { trigger = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.doubleTapWindow = doubleTapWindow
        view.trigger = trigger
    }

    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ShortcutRecorderView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 160, height: 22)
    }
}

final class ShortcutRecorderView: NSView {

    var onChange: ((Trigger) -> Void)?
    var doubleTapWindow: TimeInterval = 0.3

    var trigger: Trigger = .default {
        didSet { if trigger != oldValue { needsDisplay = true } }
    }

    private var isRecording = false {
        didSet { if isRecording != oldValue { needsDisplay = true } }
    }

    /// The first half of a double-tap: which modifier was tapped, and when it came up.
    private var pendingTap: (modifier: TriggerModifier, releasedAt: TimeInterval)?
    /// Set when anything else happens while a modifier is held, which means the user is
    /// building a chord rather than tapping.
    private var sawOtherKeyDuringHold = false
    private var heldModifier: TriggerModifier?
    /// Transient message shown in place of the shortcut, e.g. after a rejected key.
    private var notice: String?
    private var noticeTask: Task<Void, Never>?

    // MARK: - Layout

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 22) }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var isFlipped: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Recording

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        resetPending()
    }

    override func becomeFirstResponder() -> Bool {
        // Tabbing in arms the field too, so the control is reachable without a mouse.
        isRecording = true
        resetPending()
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        resetPending()
        return true
    }

    private func resetPending() {
        pendingTap = nil
        heldModifier = nil
        sawOtherKeyDuringHold = false
        notice = nil
        noticeTask?.cancel()
        needsDisplay = true
    }

    private func commit(_ trigger: Trigger) {
        self.trigger = trigger
        onChange?(trigger)
        isRecording = false
        resetPending()
        window?.makeFirstResponder(nil)
    }

    private func flash(_ message: String) {
        notice = message
        needsDisplay = true
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            self.needsDisplay = true
        }
    }

    // MARK: - Key handling

    /// Combinations that include Command are offered to key equivalents before they are
    /// delivered as key-downs, so without this ⌘-anything would reach the menu bar
    /// instead of the field.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        handleKeyDown(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return super.keyDown(with: event) }
        handleKeyDown(event)
    }

    private func handleKeyDown(_ event: NSEvent) {
        // A modifier is down and a real key followed: this is a chord, not a tap.
        pendingTap = nil
        sawOtherKeyDuringHold = true

        let modifiers = HotKey.Modifiers(eventFlags: event.modifierFlags.cgEventFlags)
        let keyCode = event.keyCode

        if modifiers.isEmpty {
            switch keyCode {
            case 0x35:  // Escape: leave the shortcut as it was.
                isRecording = false
                resetPending()
                window?.makeFirstResponder(nil)
                return
            case 0x33, 0x75:  // Delete: back to the factory trigger.
                commit(.default)
                return
            default:
                break
            }
        }

        let hotKey = HotKey(keyCode: keyCode, modifiers: modifiers)
        guard !modifiers.isEmpty || hotKey.isUsableWithoutModifiers else {
            // A bare letter would be swallowed system-wide, which would make the
            // keyboard useless rather than configure anything.
            flash("Add \u{2303}\u{2325}\u{21E7}\u{2318}")
            return
        }

        commit(.hotKey(hotKey))
    }

    /// The double-tap half. A modifier counts as tapped when it goes down and back up
    /// with nothing pressed in between; two of those inside the window is the trigger.
    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return super.flagsChanged(with: event) }

        guard let modifier = TriggerModifier(keyCode: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }

        let isDown = event.modifierFlags.cgEventFlags.contains(modifier.flag)

        if isDown {
            if heldModifier != nil { sawOtherKeyDuringHold = true }
            heldModifier = modifier
            needsDisplay = true
            return
        }

        heldModifier = nil
        guard !sawOtherKeyDuringHold else {
            sawOtherKeyDuringHold = false
            pendingTap = nil
            needsDisplay = true
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let pending = pendingTap,
           pending.modifier == modifier,
           now - pending.releasedAt <= doubleTapWindow {
            commit(.doubleTapModifier(modifier))
        } else {
            pendingTap = (modifier, now)
            needsDisplay = true
            // Nothing else announces that a second tap is expected, and a single tap
            // looking like a no-op is exactly how this feature reads as broken.
            flash("Tap \(modifier.symbol) again")
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let frame = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: frame, xRadius: 5, yRadius: 5)

        if isRecording {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
        } else {
            NSColor.textBackgroundColor.setFill()
        }
        path.fill()

        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail

        let isPlaceholder = isRecording && notice == nil
        let text = notice ?? (isRecording ? "Press a shortcut\u{2026}" : trigger.displayString)
        let colour: NSColor = isPlaceholder || notice != nil ? .secondaryLabelColor : .labelColor

        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize + 1),
            .foregroundColor: colour,
            .paragraphStyle: style,
        ])

        let size = attributed.size()
        attributed.draw(in: NSRect(
            x: frame.minX + 4,
            y: frame.midY - size.height / 2,
            width: frame.width - 8,
            height: size.height
        ))
    }

    // MARK: - Accessibility

    override func accessibilityLabel() -> String? { "Trigger shortcut" }
    override func accessibilityValue() -> Any? { trigger.displayString }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

private extension NSEvent.ModifierFlags {
    /// `HotKey.Modifiers` speaks `CGEventFlags`, because that is what the event tap
    /// hands it at match time. The two sets use the same bit values.
    var cgEventFlags: CGEventFlags {
        CGEventFlags(rawValue: UInt64(intersection(.deviceIndependentFlagsMask).rawValue))
    }
}
