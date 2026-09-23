import ApplicationServices
import BlipCore
import CoreGraphics
import Foundation

/// Private API that maps an AX element to its `CGWindowID`.
///
/// This is the only reliable way to line an app's AX window up with the entry
/// `CGWindowListCopyWindowInfo` reported for it, which is what lets occlusion work.
/// `AXScanner` falls back to matching on bounds and pid if this ever stops resolving.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement,
    _ windowID: UnsafeMutablePointer<CGWindowID>
) -> AXError

/// A typed, `Sendable` wrapper around `AXUIElement`.
///
/// `AXUIElement` is a CFType and not `Sendable`. The `@unchecked` is sound here because
/// every scanner task creates its own element references via
/// `AXUIElementCreateApplication` and never shares one with another task; the only
/// element that crosses a task boundary is the single chosen target, after scanning
/// has finished.
public struct AXElement: TargetHandle, @unchecked Sendable {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) {
        self.ref = ref
    }

    // MARK: - Raw attribute access

    func rawAttribute(_ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    func string(_ name: String) -> String? {
        guard let value = rawAttribute(name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func bool(_ name: String) -> Bool? {
        rawAttribute(name) as? Bool
    }

    func element(_ name: String) -> AXElement? {
        guard let value = rawAttribute(name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return AXElement(value as! AXUIElement)
    }

    // MARK: - Derived properties

    public var role: String? { string(kAXRoleAttribute as String) }
    public var subrole: String? { string(kAXSubroleAttribute as String) }

    /// AX exposes "is this greyed out" inconsistently. A missing attribute means the
    /// element has no concept of being disabled, which counts as enabled.
    public var isEnabled: Bool { bool(kAXEnabledAttribute as String) ?? true }

    /// Screen rectangle in CG space.
    ///
    /// `AXFrame` is a single call and is what most modern apps expose, but it is not
    /// part of the documented attribute set, so position + size remains the fallback.
    public var frame: CGRect? {
        if let value = rawAttribute("AXFrame"), CFGetTypeID(value) == AXValueGetTypeID() {
            var rect = CGRect.zero
            if AXValueGetValue(value as! AXValue, .cgRect, &rect) { return rect }
        }

        guard let positionValue = rawAttribute(kAXPositionAttribute as String),
              let sizeValue = rawAttribute(kAXSizeAttribute as String),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    public var children: [AXElement] {
        guard let value = rawAttribute(kAXChildrenAttribute as String) as? [AXUIElement] else {
            return []
        }
        return value.map(AXElement.init)
    }

    public var windows: [AXElement] {
        guard let value = rawAttribute(kAXWindowsAttribute as String) as? [AXUIElement] else {
            return []
        }
        return value.map(AXElement.init)
    }

    public var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(ref, &names) == .success,
              let list = names as? [String] else { return [] }
        return list
    }

    public var supportsPress: Bool {
        actionNames.contains(kAXPressAction as String)
    }

    /// Whether this element lives inside rendered web content (a browser page, or an
    /// Electron app's UI), found by walking up to an `AXWebArea` ancestor.
    public var isInWebArea: Bool {
        var current = element(kAXParentAttribute as String)
        for _ in 0..<64 {
            guard let node = current else { return false }
            switch node.role {
            case "AXWebArea": return true
            case "AXWindow", "AXApplication": return false
            default: current = node.element(kAXParentAttribute as String)
            }
        }
        return false
    }

    /// The `CGWindowID` of the window this element belongs to, when resolvable.
    public var windowID: CGWindowID? {
        var identifier: CGWindowID = 0
        guard _AXUIElementGetWindow(ref, &identifier) == .success, identifier != 0 else {
            return nil
        }
        return identifier
    }

    /// Friendly name for the standard window controls, which carry no title.
    ///
    /// Without this the three traffic-light buttons all show up as "Button", and the
    /// zoom button shows the sentence macOS puts in its help text
    /// ("this button also has an action to zoom the window"), which is useless as a hint.
    public var windowControlName: String? {
        switch subrole {
        case "AXCloseButton": return "Close"
        case "AXMinimizeButton": return "Minimise"
        case "AXZoomButton": return "Zoom"
        case "AXFullScreenButton": return "Full Screen"
        case "AXToolbarButton": return nil
        default: return nil
        }
    }

    /// The user-visible text for this element, in descending order of usefulness.
    ///
    /// `AXValue` comes after the title and description deliberately: for a text field
    /// the value is its *contents*, which is a better hint label than nothing but a
    /// worse one than an actual title.
    public var label: String? {
        if let title = string(kAXTitleAttribute as String) { return title }
        if let description = string(kAXDescriptionAttribute as String) { return description }
        if let value = string(kAXValueAttribute as String) { return value }
        if let help = string(kAXHelpAttribute as String) { return help }
        // Some controls carry their caption in a separate label element, e.g. a
        // checkbox whose text is a sibling static-text node.
        if let titleElement = element(kAXTitleUIElementAttribute as String),
           let title = titleElement.string(kAXTitleAttribute as String) ?? titleElement.string(kAXValueAttribute as String) {
            return title
        }
        return nil
    }

    // MARK: - Actions

    @discardableResult
    public func press() -> AXError {
        AXUIElementPerformAction(ref, kAXPressAction as CFString)
    }

    @discardableResult
    public func raiseWindow() -> AXError {
        AXUIElementPerformAction(ref, kAXRaiseAction as CFString)
    }

    public func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    /// Undocumented switch that makes Chromium and Electron apps build and expose their
    /// AX tree. Without it those apps report an empty tree and Blip sees nothing in
    /// Chrome, VS Code, Slack or Discord.
    ///
    /// Deliberately not `AXEnhancedUserInterface`, which has the same unlocking effect
    /// but is known to make some apps resize or reposition their windows when set.
    public func enableManualAccessibility() {
        AXUIElementSetAttributeValue(ref, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    public static func application(pid: pid_t) -> AXElement {
        AXElement(AXUIElementCreateApplication(pid))
    }
}
