import CoreGraphics
import Foundation

/// Opaque back-reference to whatever produced a `Target`.
///
/// `BlipCore` must not import ApplicationServices, so it cannot name `AXUIElement`.
/// `BlipKit` conforms its own `AXElement` wrapper to this protocol, which keeps the
/// actuator able to call `AXUIElementPerformAction` without dragging the Accessibility
/// framework into the headlessly-testable layer.
public protocol TargetHandle: Sendable {}

public enum TargetSource: String, Sendable, Codable, CaseIterable {
    /// Found in an app's Accessibility tree. Has a real press action; always preferred.
    case accessibility
    /// Recognised by Vision from a screenshot. Can only be actuated by a synthetic click.
    case ocr
}

/// One thing on screen a user can jump to.
///
/// Both scanners produce this, so the overlay and the actuator never need to know
/// whether a target came from the Accessibility tree or from OCR.
///
/// `frame` is always in **CG space**: points, origin at the top-left of the primary
/// display, Y increasing downward. See `Geometry` for the conversions in and out.
public struct Target: Identifiable, Sendable {
    public let id: UUID
    public var frame: CGRect
    public var label: String
    /// AX role such as `AXButton`. `nil` for OCR targets.
    public var role: String?
    public var source: TargetSource
    public var handle: TargetHandle?
    public var appName: String
    public var pid: pid_t
    public var windowID: CGWindowID?
    /// Stacking order of the owning window. 0 is frontmost.
    public var zIndex: Int
    /// Number shown in the overlay, assigned by `HintLabels`. `nil` until assigned.
    public var hint: String?

    public init(
        id: UUID = UUID(),
        frame: CGRect,
        label: String,
        role: String? = nil,
        source: TargetSource,
        handle: TargetHandle? = nil,
        appName: String = "",
        pid: pid_t = 0,
        windowID: CGWindowID? = nil,
        zIndex: Int = 0,
        hint: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.label = label
        self.role = role
        self.source = source
        self.handle = handle
        self.appName = appName
        self.pid = pid
        self.windowID = windowID
        self.zIndex = zIndex
        self.hint = hint
    }

    public var center: CGPoint {
        CGPoint(x: frame.midX, y: frame.midY)
    }

    /// What the fuzzy matcher searches over: the label plus the app name, so
    /// "saf" can pull up Safari's controls even when their own labels don't match.
    public var searchableText: String {
        label.isEmpty ? appName : "\(label) \(appName)"
    }
}
