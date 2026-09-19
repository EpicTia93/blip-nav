import CoreGraphics
import Foundation

/// Every coordinate conversion in Blip, in one place.
///
/// Three spaces are in play, and mixing them is the classic reason hints get drawn in
/// the wrong place:
///
/// - **CG space** — points, origin at the *top-left of the primary display*, Y down.
///   This is what the Accessibility API, `CGWindowListCopyWindowInfo` and `CGEvent`
///   all speak. All of `BlipCore` and `BlipKit` work exclusively in this space.
/// - **AppKit space** — points, origin at the *bottom-left of the primary display*,
///   Y up. Only used at the moment of drawing.
/// - **Vision space** — normalised 0...1, origin bottom-left, relative to the
///   captured image rather than to any display.
///
/// The conversions all take the primary display's height explicitly rather than
/// reading `NSScreen` so they stay unit-testable without a screen.
public enum Geometry {

    // MARK: - CG <-> AppKit

    /// The flip is around the primary display's height, *not* the height of whichever
    /// display the point happens to be on. A point on a secondary display above the
    /// primary correctly lands on a negative AppKit Y.
    public static func cgToAppKit(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func appKitToCG(point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// A CG rect's origin is its *top*-left; an AppKit rect's origin is its
    /// *bottom*-left. The rect conversion therefore subtracts the height as well as
    /// flipping, which is the step that naive implementations miss.
    public static func cgToAppKit(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    public static func appKitToCG(rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    // MARK: - Vision -> CG

    /// Maps a Vision normalised bounding box onto absolute CG screen coordinates.
    ///
    /// - Parameters:
    ///   - boundingBox: normalised, bottom-left origin, as Vision reports it.
    ///   - displayBounds: the captured display's bounds in CG space. The captured
    ///     image covers exactly this rect, so the image's pixel scale cancels out and
    ///     never enters the maths — which is why capturing at 1.5x costs nothing here.
    public static func visionToCG(boundingBox: CGRect, displayBounds: CGRect) -> CGRect {
        let width = boundingBox.width * displayBounds.width
        let height = boundingBox.height * displayBounds.height
        let x = displayBounds.origin.x + boundingBox.origin.x * displayBounds.width
        // Vision's Y grows upward from the image's bottom edge; CG's grows downward
        // from the display's top edge, so flip within the display and account for height.
        let y = displayBounds.origin.y
            + (1.0 - boundingBox.origin.y - boundingBox.height) * displayBounds.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Helpers

    /// Intersection-over-union. Used by `Merge` to decide whether an OCR box and an
    /// AX element describe the same thing.
    public static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    /// Clamps a rect to a container, returning nil when they do not overlap at all.
    /// Used to drop AX elements scrolled outside their scroll area.
    public static func clamp(_ rect: CGRect, to container: CGRect) -> CGRect? {
        let clamped = rect.intersection(container)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        return clamped
    }
}
