import AppKit
import BlipCore
import BlipKit
import SwiftUI

/// Everything the overlay draws, and the only place the typed query and digit prefix
/// are interpreted.
@MainActor
final class OverlayState: ObservableObject {

    /// Every target found this session, with its number already assigned. Stable for
    /// the life of the session.
    @Published private(set) var allTargets: [Target] = []
    /// `allTargets` narrowed by the current query, best match first.
    @Published private(set) var visibleTargets: [Target] = []
    /// Letters typed so far. Filters.
    @Published private(set) var query = ""
    /// Digits typed so far. Selects.
    @Published private(set) var digitPrefix = ""
    @Published var isScanningOCR = false
    @Published var notice: String?

    var isEmpty: Bool { allTargets.isEmpty }

    /// The target Enter would activate: the best remaining match.
    var topMatch: Target? { visibleTargets.first }

    func reset() {
        allTargets = []
        visibleTargets = []
        query = ""
        digitPrefix = ""
        isScanningOCR = false
        notice = nil
    }

    func setTargets(_ targets: [Target]) {
        allTargets = targets
        recompute()
    }

    /// Adds the OCR pass's results. They are appended rather than merged in-place so
    /// every number already on screen keeps meaning what it meant a moment ago.
    func appendTargets(_ targets: [Target]) {
        allTargets.append(contentsOf: targets)
        recompute()
    }

    func appendQueryCharacter(_ character: String) {
        query += character
        // A new letter can filter away whatever the digits were pointing at, so the
        // half-typed number is no longer meaningful.
        digitPrefix = ""
        recompute()
    }

    func appendDigit(_ digit: String) {
        digitPrefix += digit
    }

    func clearDigitPrefix() {
        digitPrefix = ""
    }

    /// Backspace removes from whichever buffer the user was last filling.
    func deleteBackward() {
        if !digitPrefix.isEmpty {
            digitPrefix.removeLast()
        } else if !query.isEmpty {
            query.removeLast()
            recompute()
        }
    }

    /// Resolves the typed digits against what is currently *visible*.
    ///
    /// Filtered-out targets are deliberately not selectable: their numbers are no
    /// longer on screen, so letting them fire would be invisible action at a distance.
    func resolveDigits() -> HintResolution {
        HintLabels.resolve(prefix: digitPrefix, in: visibleTargets)
    }

    func target(id: UUID) -> Target? {
        allTargets.first { $0.id == id }
    }

    private func recompute() {
        visibleTargets = Matcher.filter(allTargets, query: query)
    }
}
