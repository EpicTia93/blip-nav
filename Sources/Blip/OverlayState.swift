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
    /// Where Tab has stepped the pointer to, once the user has moved off the best
    /// match. Held as an id rather than an index so the OCR pass landing mid-session
    /// cannot slide the pointer onto some other target under the user's hand.
    @Published private(set) var selectionID: UUID?
    @Published var isScanningOCR = false
    @Published var notice: String?

    var isEmpty: Bool { allTargets.isEmpty }

    /// The target Enter would activate, and the one the pointer is drawn to: the best
    /// remaining match, unless Tab has stepped the pointer somewhere else.
    var topMatch: Target? {
        if let selectionID, let stepped = visibleTargets.first(where: { $0.id == selectionID }) {
            return stepped
        }
        return visibleTargets.first
    }

    /// Whether the pointer should be drawn at all. A query narrows things down to the
    /// point where singling one out is useful; Tab says so outright.
    var hasPointer: Bool { !query.isEmpty || selectionID != nil }

    func reset() {
        allTargets = []
        visibleTargets = []
        query = ""
        digitPrefix = ""
        selectionID = nil
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
        // half-typed number is no longer meaningful. The same goes for a stepped
        // pointer: the match it sat on may not survive the narrower query.
        digitPrefix = ""
        selectionID = nil
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
            selectionID = nil
            recompute()
        }
    }

    /// Steps the pointer through the remaining matches. Wrapping means Tab on its own
    /// reaches every one of them, so there is nothing to learn beyond the one key.
    func selectNext() { moveSelection(by: 1) }

    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !visibleTargets.isEmpty else { return }
        let current = selectionID.flatMap { id in
            visibleTargets.firstIndex { $0.id == id }
        } ?? 0
        let count = visibleTargets.count
        let next = ((current + offset) % count + count) % count
        selectionID = visibleTargets[next].id
        // Moving the pointer by hand supersedes a half-typed number, the same way
        // typing another letter does.
        digitPrefix = ""
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
