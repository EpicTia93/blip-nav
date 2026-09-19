import CoreGraphics
import Foundation

/// An on-screen window, as reported by `CGWindowListCopyWindowInfo`.
///
/// `bounds` is in CG space. `zIndex` preserves the front-to-back order the window
/// server reports, with 0 frontmost.
public struct ScreenWindow: Sendable, Identifiable, Equatable {
    public let id: CGWindowID
    public var pid: pid_t
    public var appName: String
    public var title: String?
    public var bounds: CGRect
    /// `kCGWindowLayer`. 0 is a normal app window; the Dock and menu bar sit higher.
    public var layer: Int
    public var zIndex: Int

    public init(
        id: CGWindowID,
        pid: pid_t,
        appName: String,
        title: String? = nil,
        bounds: CGRect,
        layer: Int = 0,
        zIndex: Int = 0
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.zIndex = zIndex
    }

    /// Normal app windows live on layer 0. Anything above is system chrome
    /// (Dock, menu bar, notifications), which we keep but treat separately.
    public var isNormalWindow: Bool { layer == 0 }
}
