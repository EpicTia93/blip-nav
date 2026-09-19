import BlipCore
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

public struct OCROptions: Sendable {
    /// Languages passed to Vision. Order matters: the first is preferred when a string
    /// is ambiguous between them.
    public var languages: [String] = ["it-IT", "en-US"]
    /// `.accurate` is worth its cost here; `.fast` mangles short UI labels badly.
    public var usesAccurateRecognition = true
    /// Fraction of the display height below which text is ignored. Filters out
    /// watermark-sized noise without dropping ordinary 11pt UI labels.
    public var minimumTextHeightFraction: Float = 0.008
    /// A recognised line wider than this fraction of the display is a sentence rather
    /// than a label, so it is also split into individually targetable words.
    public var wordSplitWidthFraction: CGFloat = 0.4
    /// Vision's own confidence floor.
    public var minimumConfidence: Float = 0.3
    /// Capture scale relative to points. Retina's native 2x doubles Vision's work for
    /// no measurable gain on UI text, which is large and high-contrast by nature.
    public var captureScale: CGFloat = 1.5

    public init() {}
}

public struct OCRScanOutcome: Sendable {
    public var targets: [Target]
    public var duration: TimeInterval
    /// Split out because the two halves are tuned differently: capture time is a
    /// function of resolution, recognition time of resolution *and* how much text is
    /// on screen.
    public var captureDuration: TimeInterval
    public var recognizeDuration: TimeInterval
    public var error: String?
}

/// Reads on-screen text with Vision, for everything the Accessibility tree cannot see:
/// canvas-rendered apps, remote desktops, games, screenshots, PDFs, and the many
/// Electron windows that expose a hollow AX tree.
///
/// Language correction is deliberately **off**. It is tuned for prose and actively
/// corrupts UI labels, which are short, frequently product names, and often not words
/// in any dictionary.
public enum OCRScanner {

    /// Bounds of every active display, in CG space.
    ///
    /// `CGDisplayBounds` already speaks CG coordinates (top-left origin of the primary
    /// display), so no conversion is needed and none should be added.
    public static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map(CGDisplayBounds)
    }

    public static func scan(
        displays: [CGRect]? = nil,
        options: OCROptions = OCROptions()
    ) async -> OCRScanOutcome {
        let started = Date()
        let bounds = displays ?? activeDisplayBounds()
        guard !bounds.isEmpty else {
            return OCRScanOutcome(targets: [], duration: 0, captureDuration: 0,
                                  recognizeDuration: 0, error: "no active displays")
        }

        // One shareable-content query covers every display. It is not cheap, and it
        // must be fresh each scan because it is also what lets us exclude our own
        // overlay -- without that, Vision reads the hint numbers Blip just drew and
        // turns them into targets of their own.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            return OCRScanOutcome(
                targets: [], duration: Date().timeIntervalSince(started),
                captureDuration: 0, recognizeDuration: 0, error: "\(error)"
            )
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let ownApps = content.applications.filter {
            $0.bundleIdentifier == ownBundleID
                || $0.processID == ProcessInfo.processInfo.processIdentifier
        }

        var targets: [Target] = []
        var firstError: String?
        var captureTotal: TimeInterval = 0
        var recognizeTotal: TimeInterval = 0

        await withTaskGroup(of: Result<DisplayResult, Error>.self) { group in
            for displayBounds in bounds {
                let display = content.displays.first {
                    CGDisplayBounds($0.displayID) == displayBounds
                }
                group.addTask {
                    do {
                        return .success(try await scanDisplay(
                            displayBounds,
                            display: display,
                            excluding: ownApps,
                            options: options
                        ))
                    } catch {
                        return .failure(error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .success(let found):
                    targets.append(contentsOf: found.targets)
                    captureTotal = max(captureTotal, found.captureDuration)
                    recognizeTotal = max(recognizeTotal, found.recognizeDuration)
                case .failure(let error):
                    firstError = firstError ?? "\(error)"
                }
            }
        }

        return OCRScanOutcome(
            targets: targets,
            duration: Date().timeIntervalSince(started),
            captureDuration: captureTotal,
            recognizeDuration: recognizeTotal,
            error: firstError
        )
    }

    struct DisplayResult: Sendable {
        var targets: [Target]
        var captureDuration: TimeInterval
        var recognizeDuration: TimeInterval
    }

    // MARK: - One display

    private static func scanDisplay(
        _ bounds: CGRect,
        display: SCDisplay?,
        excluding ownApps: [SCRunningApplication],
        options: OCROptions
    ) async throws -> DisplayResult {
        let captureStarted = Date()
        let image: CGImage
        if let display {
            let filter = SCContentFilter(
                display: display,
                excludingApplications: ownApps,
                exceptingWindows: []
            )
            let configuration = SCStreamConfiguration()
            configuration.width = Int(bounds.width * options.captureScale)
            configuration.height = Int(bounds.height * options.captureScale)
            configuration.captureResolution = .best
            configuration.showsCursor = false
            image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
        } else {
            // No matching SCDisplay (rare: a display appeared between enumeration and
            // capture). Fall back to the simple path rather than dropping the display.
            image = try await SCScreenshotManager.captureImage(in: bounds)
        }
        let captureDuration = Date().timeIntervalSince(captureStarted)

        let recognizeStarted = Date()
        var request = RecognizeTextRequest()
        request.recognitionLevel = options.usesAccurateRecognition ? .accurate : .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeightFraction = options.minimumTextHeightFraction
        request.recognitionLanguages = options.languages.map(Locale.Language.init(identifier:))

        let observations = try await request.perform(on: image)

        var targets: [Target] = []
        for observation in observations {
            guard observation.confidence >= options.minimumConfidence else { continue }
            guard let candidate = observation.topCandidates(1).first else { continue }

            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let frame = cgRect(from: observation.boundingBox, in: bounds)

            // A long line is a sentence, not a label. Hinting it as one blob would make
            // it unselectable in any useful sense, so break it into words instead.
            if frame.width > bounds.width * options.wordSplitWidthFraction,
               let words = splitIntoWords(candidate, text: text, displayBounds: bounds),
               words.count > 1 {
                targets.append(contentsOf: words)
            } else {
                targets.append(makeTarget(text: text, frame: frame))
            }
        }
        return DisplayResult(
            targets: targets,
            captureDuration: captureDuration,
            recognizeDuration: Date().timeIntervalSince(recognizeStarted)
        )
    }

    private static func splitIntoWords(
        _ candidate: RecognizedText,
        text: String,
        displayBounds: CGRect
    ) -> [Target]? {
        var targets: [Target] = []
        var searchStart = text.startIndex

        while searchStart < text.endIndex {
            // Skip leading whitespace, then take the run up to the next space.
            guard let wordStart = text[searchStart...].firstIndex(where: { !$0.isWhitespace })
            else { break }
            let wordEnd = text[wordStart...].firstIndex(where: \.isWhitespace) ?? text.endIndex
            let range = wordStart..<wordEnd
            let word = String(text[range])
            searchStart = wordEnd

            // Single characters are almost always punctuation left over from the split.
            guard word.count > 1 else { continue }
            guard let box = candidate.boundingBox(for: range) else { continue }

            targets.append(
                makeTarget(text: word, frame: cgRect(from: box.boundingBox, in: displayBounds))
            )
        }

        return targets.isEmpty ? nil : targets
    }

    private static func cgRect(from normalized: NormalizedRect, in displayBounds: CGRect) -> CGRect {
        Geometry.visionToCG(
            boundingBox: CGRect(
                x: normalized.origin.x,
                y: normalized.origin.y,
                width: normalized.width,
                height: normalized.height
            ),
            displayBounds: displayBounds
        )
    }

    private static func makeTarget(text: String, frame: CGRect) -> Target {
        Target(
            frame: frame,
            label: text,
            role: nil,
            source: .ocr,
            handle: nil,
            appName: "",
            pid: 0,
            windowID: nil,
            zIndex: Int.max
        )
    }
}
