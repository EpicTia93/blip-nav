import AppKit
import CoreGraphics
import Foundation

/// A keystroke captured while the overlay is up.
public struct CapturedKey: Sendable, Equatable {
    public var keyCode: CGKeyCode
    /// Characters the key would have produced, already interpreted through the
    /// current keyboard layout.
    public var characters: String
    public var flags: CGEventFlags

    public var isEscape: Bool { keyCode == 0x35 }
    public var isReturn: Bool { keyCode == 0x24 || keyCode == 0x4C }
    public var isDelete: Bool { keyCode == 0x33 }
    public var isTab: Bool { keyCode == 0x30 }
    public var isSpace: Bool { keyCode == 0x31 }
}

/// The single `CGEventTap` behind both the trigger and overlay key capture.
///
/// One tap does both jobs because two taps on the same stream would race over who gets
/// to swallow a keystroke. While idle it watches for the double-tapped modifier; while
/// `isCapturing` is set it swallows every key and hands it to `onKey` instead, so
/// nothing leaks into the app underneath.
///
/// The tap lives at `.cgSessionEventTap`, which Accessibility permission alone is
/// enough to authorise. `.cghidEventTap` would additionally require Input Monitoring,
/// which is a second grant to explain to the user for no benefit here.
public final class TriggerTap {

    // MARK: - Callbacks

    /// Called on the main queue when the trigger fires.
    public var onTrigger: (@MainActor () -> Void)?
    /// Called on the main queue for each swallowed keystroke while capturing.
    public var onKey: (@MainActor (CapturedKey) -> Void)?

    /// Read by the tap callback on every keystroke, so it must stay a plain atomic-ish
    /// read. Only ever written from the main thread.
    public private(set) var isCapturing = false

    public var configuration: Configuration

    // MARK: - State

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastModifierReleaseTime: CFAbsoluteTime = 0
    /// Set when any other key is pressed while the trigger modifier is down, which
    /// means the modifier is being used as part of a chord rather than tapped.
    private var sawOtherKeyDuringHold = false
    private var modifierIsDown = false

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    deinit {
        stopSynchronously()
    }

    // MARK: - Lifecycle

    public enum StartError: Error, CustomStringConvertible {
        case notTrusted
        case tapCreationFailed

        public var description: String {
            switch self {
            case .notTrusted: return "Accessibility permission has not been granted"
            case .tapCreationFailed: return "the system refused to create an event tap"
            }
        }
    }

    public func start() throws {
        guard Permissions.hasAccessibility else { throw StartError.notTrusted }
        guard tap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // The callback is a bare C function pointer and cannot capture, so `self` is
        // threaded through `userInfo` as an unretained pointer. Unretained is correct:
        // the tap never outlives its owner, which invalidates it in `deinit`.
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { proxy, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<TriggerTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw StartError.tapCreationFailed
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        Log.tap.notice("event tap started, trigger=\(self.configuration.triggerModifier.rawValue, privacy: .public) keyCode=\(self.configuration.triggerModifier.keyCode)")
    }

    public func stop() {
        stopSynchronously()
    }

    private func stopSynchronously() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    @MainActor
    public func beginCapture() {
        isCapturing = true
    }

    @MainActor
    public func endCapture() {
        isCapturing = false
        // A session may well have ended with the modifier still down; forget any
        // half-finished double-tap so the next one starts clean.
        lastModifierReleaseTime = 0
        sawOtherKeyDuringHold = false
    }

    // MARK: - Tap callback

    /// Runs on the run loop thread for *every* keystroke on the system, so it does the
    /// minimum possible work and hands anything real to the main queue.
    private func handle(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // macOS disables a tap whose callback runs too slowly, and says nothing about
        // it. Without re-enabling here, Blip would simply stop responding to its own
        // hotkey partway through a session, with no error anywhere.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.tap.error("tap was disabled by the system (\(type.rawValue)); re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        if isCapturing {
            switch type {
            case .keyDown:
                let press = CapturedKey(
                    keyCode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    characters: Self.characters(from: event),
                    flags: event.flags
                )
                MainActor.assumeIsolated { onKey?(press) }
                // Swallow: the app underneath must not see the user driving the overlay.
                return nil
            case .flagsChanged:
                return Unmanaged.passUnretained(event)
            default:
                return Unmanaged.passUnretained(event)
            }
        }

        switch type {
        case .keyDown:
            // Any other key means the modifier is part of a chord, not a tap.
            sawOtherKeyDuringHold = true
            lastModifierReleaseTime = 0
        case .flagsChanged:
            handleFlagsChanged(event)
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == configuration.triggerModifier.keyCode else {
            // A different modifier joined in; that is a chord.
            if modifierIsDown { sawOtherKeyDuringHold = true }
            return
        }

        let isDown = Self.isModifierDown(configuration.triggerModifier, flags: event.flags)
        Log.tap.debug("trigger modifier \(isDown ? "down" : "up", privacy: .public) sawOther=\(self.sawOtherKeyDuringHold) gap=\(CFAbsoluteTimeGetCurrent() - self.lastModifierReleaseTime)")

        if isDown {
            modifierIsDown = true
            sawOtherKeyDuringHold = false
            return
        }

        modifierIsDown = false
        guard !sawOtherKeyDuringHold else {
            lastModifierReleaseTime = 0
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastModifierReleaseTime <= configuration.doubleTapWindow {
            lastModifierReleaseTime = 0
            Log.tap.notice("double-tap detected, firing trigger")
            MainActor.assumeIsolated { onTrigger?() }
        } else {
            lastModifierReleaseTime = now
        }
    }

    /// `flagsChanged` reports the state *after* the change, so the modifier's bit being
    /// set means it was just pressed and cleared means it was just released.
    private static func isModifierDown(_ modifier: TriggerModifier, flags: CGEventFlags) -> Bool {
        switch modifier {
        case .rightCommand, .leftCommand: return flags.contains(.maskCommand)
        case .rightOption, .leftOption: return flags.contains(.maskAlternate)
        case .rightControl: return flags.contains(.maskControl)
        case .rightShift: return flags.contains(.maskShift)
        }
    }

    private static func characters(from event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
