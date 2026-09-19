import CoreGraphics
import Foundation

/// Drops targets that are hidden behind other windows.
///
/// This matters far more here than in a single-app hinting tool: scanning every app
/// means the Accessibility tree happily reports controls in windows that are stacked
/// three deep behind the browser. Labelling those would be worse than useless, because
/// the number would be drawn on top of whatever is actually visible at that point.
public enum Occlusion {

    /// True when `point` is not covered by any window stacked in front of `zIndex`.
    ///
    /// Only windows with a strictly smaller `zIndex` (i.e. nearer the front) can
    /// occlude, so a window never hides its own contents.
    public static func isVisible(
        point: CGPoint,
        ownerZIndex zIndex: Int,
        windows: [ScreenWindow]
    ) -> Bool {
        for window in windows where window.zIndex < zIndex {
            if window.bounds.contains(point) { return false }
        }
        return true
    }

    /// Filters a target list down to what a user can actually see and click.
    ///
    /// Uses the target's centre rather than its whole frame: a button half-covered by
    /// a floating palette is still clickable at its centre, whereas requiring the full
    /// frame to be clear would throw away most of a partially overlapped window.
    public static func filterVisible(
        _ targets: [Target],
        windows: [ScreenWindow]
    ) -> [Target] {
        guard !windows.isEmpty else { return targets }
        // Index by id so each target can find its own window's depth cheaply.
        var depthByWindow: [CGWindowID: Int] = [:]
        for window in windows { depthByWindow[window.id] = window.zIndex }

        return targets.filter { target in
            // OCR targets have no owning window; they were read off the composited
            // screen image, so by construction they are already what is visible.
            guard let windowID = target.windowID,
                  let depth = depthByWindow[windowID] else { return true }
            return isVisible(point: target.center, ownerZIndex: depth, windows: windows)
        }
    }

    // MARK: - Whole-window culling

    /// True when nothing of `window` is left visible once every window in front of it
    /// has been subtracted.
    ///
    /// This is a pure optimisation, but a decisive one. Walking the Accessibility tree
    /// of a buried window costs the same as walking a visible one -- hundreds of
    /// milliseconds for a big app -- and every target it produces is then thrown away
    /// by `filterVisible` anyway. Culling first turns that into zero work.
    public static func isFullyOccluded(_ window: ScreenWindow, by windows: [ScreenWindow]) -> Bool {
        var uncovered = [window.bounds]
        for other in windows where other.zIndex < window.zIndex {
            guard !uncovered.isEmpty else { return true }
            uncovered = uncovered.flatMap { subtract(other.bounds, from: $0) }
        }
        return uncovered.isEmpty
    }

    /// Splits `rect` into the pieces not covered by `cover`.
    ///
    /// Returns up to four rects: the strips above, below, left and right of the
    /// intersection. An empty result means `cover` swallowed `rect` entirely.
    static func subtract(_ cover: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = cover.intersection(rect)
        guard !overlap.isNull, !overlap.isEmpty else { return [rect] }
        if overlap.contains(rect) { return [] }

        var pieces: [CGRect] = []
        // Above the overlap.
        if overlap.minY > rect.minY {
            pieces.append(CGRect(x: rect.minX, y: rect.minY,
                                 width: rect.width, height: overlap.minY - rect.minY))
        }
        // Below the overlap.
        if overlap.maxY < rect.maxY {
            pieces.append(CGRect(x: rect.minX, y: overlap.maxY,
                                 width: rect.width, height: rect.maxY - overlap.maxY))
        }
        // Left of the overlap, spanning only the overlap's vertical extent so the
        // pieces stay disjoint.
        if overlap.minX > rect.minX {
            pieces.append(CGRect(x: rect.minX, y: overlap.minY,
                                 width: overlap.minX - rect.minX, height: overlap.height))
        }
        // Right of the overlap.
        if overlap.maxX < rect.maxX {
            pieces.append(CGRect(x: overlap.maxX, y: overlap.minY,
                                 width: rect.maxX - overlap.maxX, height: overlap.height))
        }
        return pieces
    }
}
