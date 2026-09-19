import AppKit
import BlipCore
import CoreGraphics
import Foundation

/// Sequences a full activation: enumerate windows, walk AX trees, OCR the screen,
/// merge, discard what is hidden, and number what is left.
///
/// Split into two passes on purpose. Accessibility finishes in tens of milliseconds and
/// its hints go up immediately; OCR takes several times longer and its results are
/// *appended*, keeping every number already on screen valid. Renumbering under the
/// user's fingers mid-keystroke would be worse than showing fewer targets.
public enum ScanCoordinator {

    public struct AccessibilityPass: Sendable {
        public var targets: [Target]
        public var windows: [ScreenWindow]
        public var duration: TimeInterval
        public var perAppTimings: [String: TimeInterval]
        public var truncatedApps: [String]
    }

    public struct OCRPass: Sendable {
        public var targets: [Target]
        /// How many lines Vision recognised before deduplication against the
        /// Accessibility pass. Useful for telling "OCR found nothing" apart from
        /// "OCR found plenty, all of it already covered".
        public var rawCount: Int = 0
        public var duration: TimeInterval
        public var captureDuration: TimeInterval
        public var recognizeDuration: TimeInterval
        public var error: String?
    }

    /// Pass one: windows plus everything the Accessibility tree exposes, numbered from 1.
    public static func accessibilityPass(
        options: AXScanOptions = AXScanOptions()
    ) async -> AccessibilityPass {
        let started = Date()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = WindowEnumerator.onScreenWindows(excludingPID: ownPID)

        let outcome = await AXScanner.scan(windows: windows, options: options)
        let visible = Occlusion.filterVisible(outcome.targets, windows: windows)
        let numbered = HintLabels.assign(visible)

        return AccessibilityPass(
            targets: numbered,
            windows: windows,
            duration: Date().timeIntervalSince(started),
            perAppTimings: outcome.timings,
            truncatedApps: outcome.truncatedApps
        )
    }

    /// Pass two: OCR, deduped against what pass one already found, numbered from where
    /// pass one left off.
    public static func ocrPass(
        existing: [Target],
        options: OCROptions = OCROptions()
    ) async -> OCRPass {
        let outcome = await OCRScanner.scan(options: options)
        let accessibilityTargets = existing.filter { $0.source == .accessibility }

        // `combine` returns AX + surviving OCR; only the new OCR targets need numbers.
        let combined = Merge.combine(accessibility: accessibilityTargets, ocr: outcome.targets)
        let fresh = combined.filter { $0.source == .ocr }
        let numbered = HintLabels.assign(fresh, startingAt: existing.count + 1)

        return OCRPass(
            targets: numbered,
            rawCount: outcome.targets.count,
            duration: outcome.duration,
            captureDuration: outcome.captureDuration,
            recognizeDuration: outcome.recognizeDuration,
            error: outcome.error
        )
    }

    /// Both passes, for callers that want the finished list in one call. Used by
    /// `blip-probe`; the overlay uses the two passes separately so it can draw early.
    public static func full(
        axOptions: AXScanOptions = AXScanOptions(),
        ocrOptions: OCROptions = OCROptions(),
        includeOCR: Bool = true
    ) async -> (accessibility: AccessibilityPass, ocr: OCRPass?) {
        let ax = await accessibilityPass(options: axOptions)
        guard includeOCR, Permissions.hasScreenRecording else { return (ax, nil) }
        let ocr = await ocrPass(existing: ax.targets, options: ocrOptions)
        return (ax, ocr)
    }
}
