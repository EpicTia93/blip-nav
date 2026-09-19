import Foundation

/// Fuzzy subsequence matching for the search bar.
///
/// Deliberately diacritic- and case-insensitive: the UI being targeted is frequently
/// Italian, so `piu` has to match `più` and `acq` has to match `Acquista` without the
/// user reaching for a dead key mid-flow.
public enum Matcher {

    /// Characters after which the next character counts as starting a new word.
    private static let separators: Set<Character> = [
        " ", "\t", "\n", "-", "_", "/", "\\", ".", ",", ":", ";",
        "(", ")", "[", "]", "{", "}", "'", "\"", "&", "+", "|", "\u{00A0}",
    ]

    /// Folds diacritics and full-width forms but *keeps case*, because case is what
    /// reveals camelCase word boundaries further down.
    public static func fold(_ string: String) -> String {
        string.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func lowered(_ character: Character) -> Character {
        character.lowercased().first ?? character
    }

    private static func isWordStart(_ characters: [Character], _ index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if separators.contains(previous) { return true }
        // camelCase / PascalCase boundary, e.g. the "B" in "AirPodsBattery".
        return previous.isLowercase && characters[index].isUppercase
    }

    /// Scores `query` against `candidate`, or returns nil when `query` is not a
    /// subsequence of it. Higher is better.
    ///
    /// The weights favour, in order: matching at the very start, matching at a word
    /// start, and matching contiguously. That is what makes `acq` rank `Acquista`
    /// above a label that merely happens to contain a, c and q scattered about.
    public static func score(query: String, candidate: String) -> Int? {
        let queryChars = Array(fold(query)).map(lowered)
        guard !queryChars.isEmpty else { return 0 }

        let candidateChars = Array(fold(candidate))
        guard queryChars.count <= candidateChars.count else { return nil }
        let candidateLower = candidateChars.map(lowered)

        var queryIndex = 0
        var total = 0
        var previousMatch = -2
        var firstMatch: Int?

        for index in candidateLower.indices {
            guard queryIndex < queryChars.count,
                  candidateLower[index] == queryChars[queryIndex] else { continue }

            var points = 10
            if index == previousMatch + 1 { points += 15 }
            if index == 0 {
                points += 20
            } else if isWordStart(candidateChars, index) {
                points += 12
            }

            total += points
            previousMatch = index
            if firstMatch == nil { firstMatch = index }
            queryIndex += 1
        }

        guard queryIndex == queryChars.count else { return nil }

        // Prefer tight, early matches: a short label that matches near its start beats
        // a long one that only matches near its end.
        total -= (candidateChars.count - queryChars.count) / 2
        total -= firstMatch ?? 0
        return total
    }

    /// Returns the targets matching `query`, best first. An empty query matches
    /// everything and preserves the existing order.
    public static func filter(_ targets: [Target], query: String) -> [Target] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return targets }

        return targets
            .compactMap { target -> (Target, Int)? in
                guard let score = score(query: trimmed, candidate: target.searchableText) else {
                    return nil
                }
                return (target, score)
            }
            .enumerated()
            // Stable sort: ties fall back to the original (reading) order so the
            // overlay never reshuffles equal-scoring hints as the user types.
            .sorted { lhs, rhs in
                if lhs.element.1 != rhs.element.1 { return lhs.element.1 > rhs.element.1 }
                return lhs.offset < rhs.offset
            }
            .map(\.element.0)
    }
}
