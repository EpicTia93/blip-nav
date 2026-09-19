import AppKit
import BlipCore
import CoreGraphics

/// Bridges `NSScreen` (AppKit space) to the CG space everything else uses.
@MainActor
public enum ScreenInfo {

    /// The display whose AppKit origin is (0,0). Every CG<->AppKit flip is measured
    /// against this one, never against whichever display a rect happens to sit on.
    public static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    public static var primaryHeight: CGFloat {
        primaryScreen?.frame.height ?? 0
    }

    /// A screen's bounds in CG space.
    public static func cgBounds(of screen: NSScreen) -> CGRect {
        Geometry.appKitToCG(rect: screen.frame, primaryHeight: primaryHeight)
    }

    /// Converts a CG-space rect into coordinates local to `screen`.
    ///
    /// SwiftUI's coordinate space inside a hosting view is top-left origin with Y
    /// increasing downward -- the same convention as CG space. So once the screen's own
    /// CG origin is subtracted, no flip is needed at all, which removes the last place
    /// a sign error could creep in.
    public static func localRect(_ rect: CGRect, on screen: NSScreen) -> CGRect {
        let bounds = cgBounds(of: screen)
        return CGRect(
            x: rect.origin.x - bounds.origin.x,
            y: rect.origin.y - bounds.origin.y,
            width: rect.width,
            height: rect.height
        )
    }

    /// The screen a CG-space point falls on, for splitting targets across displays.
    public static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgBounds(of: $0).contains(point) }
    }
}
