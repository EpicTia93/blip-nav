import AppKit
import BlipCore
import CoreGraphics

/// Lists the windows actually on screen, front to back.
///
/// This runs before every scan and is the cheapest part of the pipeline (~2ms). Its
/// output does double duty: it tells the AX scanner which windows are worth walking,
/// and it gives `Occlusion` the stacking order it needs to discard hidden controls.
public enum WindowEnumerator {

    /// Windows smaller than this in either dimension are tooltips, shadows and
    /// one-pixel helper windows, never something worth hinting.
    public static let minimumWindowSize: CGFloat = 20

    /// Fully transparent windows are still "on screen" as far as the window server is
    /// concerned. Several apps park invisible windows over the desktop.
    public static let minimumAlpha: CGFloat = 0.05

    /// `CGWindowListCopyWindowInfo` returns windows front to back, which is exactly the
    /// z-order we need, so the index in the returned array *is* the depth.
    public static func onScreenWindows(excludingPID excluded: pid_t? = nil) -> [ScreenWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var result: [ScreenWindow] = []
        var depth = 0

        for entry in raw {
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            if let excluded, pid == excluded { continue }

            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard isInterestingLayer(layer) else { continue }

            let alpha = entry[kCGWindowAlpha as String] as? CGFloat ?? 1
            guard alpha > minimumAlpha else { continue }
            guard bounds.width >= minimumWindowSize, bounds.height >= minimumWindowSize else { continue }

            result.append(
                ScreenWindow(
                    id: windowID,
                    pid: pid,
                    appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                    // kCGWindowName is nil without Screen Recording permission, which
                    // is fine -- it is only ever used for debugging output.
                    title: entry[kCGWindowName as String] as? String,
                    bounds: bounds,
                    layer: layer,
                    zIndex: depth
                )
            )
            depth += 1
        }

        return result
    }

    /// Layer 0 holds ordinary app windows. The Dock, menu bar and status items sit at
    /// 20-25 and are worth hinting too. Everything else is system furniture: wallpaper,
    /// desktop icons (negative layers), screen-saver and cursor windows.
    private static func isInterestingLayer(_ layer: Int) -> Bool {
        layer == 0 || (layer >= 20 && layer <= 25)
    }

    /// Groups windows by owning process, so the AX scanner can spin up one task per app
    /// and hand it only the windows that are actually visible.
    public static func groupedByPID(_ windows: [ScreenWindow]) -> [pid_t: [ScreenWindow]] {
        Dictionary(grouping: windows, by: \.pid)
    }
}
