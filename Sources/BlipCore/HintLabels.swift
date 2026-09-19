import CoreGraphics
import Foundation

/// What typing a digit prefix currently means.
public enum HintResolution: Equatable, Sendable {
    /// No target's number starts with this prefix. The keystroke was a dead end.
    case none
    /// Exactly one target matches and nothing can extend the prefix. Fire immediately.
    case exact(UUID)
    /// The prefix is still growable. `exactMatch` is non-nil when the prefix is itself
    /// a complete number (typed "1" while "12" also exists), in which case it is what
    /// Enter or the timeout should fire.
    case pending(exactMatch: UUID?)
}

/// Assigns the numbers shown in the overlay, and interprets the digits typed back.
public enum HintLabels {

    /// Vertical tolerance, in points, for treating two targets as being on the same
    /// visual row. Without this, controls in a toolbar whose tops differ by a pixel
    /// get numbered in a jarring zig-zag instead of left-to-right.
    public static let rowBandHeight: CGFloat = 12

    /// Numbers targets in reading order: frontmost window first, then top-to-bottom,
    /// then left-to-right within each row.
    ///
    /// Numbering is stable for the lifetime of an overlay session. That is what lets
    /// digits and letters coexist without ambiguity: digits always select and letters
    /// always filter, so filtering can never renumber a target out from under a
    /// half-typed number.
    public static func assign(_ targets: [Target], startingAt start: Int = 1) -> [Target] {
        let ordered = targets
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (lhs.element, rhs.element)
                if a.zIndex != b.zIndex { return a.zIndex < b.zIndex }
                let rowA = (a.frame.minY / rowBandHeight).rounded(.down)
                let rowB = (b.frame.minY / rowBandHeight).rounded(.down)
                if rowA != rowB { return rowA < rowB }
                if a.frame.minX != b.frame.minX { return a.frame.minX < b.frame.minX }
                // Final tiebreak on original index keeps the sort deterministic for
                // targets that land on exactly the same point.
                return lhs.offset < rhs.offset
            }
            .map(\.element)

        return ordered.enumerated().map { index, target in
            var copy = target
            copy.hint = String(index + start)
            return copy
        }
    }

    /// Interprets a partially typed number against the currently shown targets.
    ///
    /// This is the Vimium rule. Typing "1" when targets 1 and 12 both exist cannot fire
    /// straight away, but typing "3" when nothing starts "3x" should not make the user
    /// wait. Callers hold `.pending` results until another digit arrives, Enter is
    /// pressed, or a short timeout elapses.
    public static func resolve(prefix: String, in targets: [Target]) -> HintResolution {
        guard !prefix.isEmpty else { return .pending(exactMatch: nil) }

        var exactMatch: UUID?
        var hasExtension = false

        for target in targets {
            guard let hint = target.hint, hint.hasPrefix(prefix) else { continue }
            if hint.count == prefix.count {
                exactMatch = target.id
            } else {
                hasExtension = true
            }
        }

        if let exactMatch, !hasExtension { return .exact(exactMatch) }
        if exactMatch == nil, !hasExtension { return .none }
        return .pending(exactMatch: exactMatch)
    }
}
