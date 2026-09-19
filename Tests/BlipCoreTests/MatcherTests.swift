import Testing
@testable import BlipCore

@Suite("Matcher")
struct MatcherTests {

    @Test("Non-subsequences do not match")
    func rejectsNonSubsequence() {
        #expect(Matcher.score(query: "zzz", candidate: "Acquista") == nil)
        #expect(Matcher.score(query: "acquistaa", candidate: "Acquista") == nil)
    }

    @Test("acq ranks Acquista above AirPods")
    func rankingAcquista() {
        let acquista = Matcher.score(query: "acq", candidate: "Acquista")
        let airpods = Matcher.score(query: "acq", candidate: "AirPods Comparison Quiz")
        #expect(acquista != nil)
        // AirPods only matches a, c, q scattered across words; Acquista matches them
        // contiguously from the very start.
        if let acquista, let airpods { #expect(acquista > airpods) }
    }

    @Test("Diacritics fold, so piu matches piu-with-accent")
    func diacriticFolding() {
        #expect(Matcher.score(query: "piu", candidate: "Scopri di più") != nil)
        #expect(Matcher.score(query: "piu", candidate: "più") != nil)
    }

    @Test("Matching is case-insensitive in both directions")
    func caseInsensitive() {
        #expect(Matcher.score(query: "ACQ", candidate: "Acquista") != nil)
        #expect(Matcher.score(query: "acq", candidate: "ACQUISTA") != nil)
    }

    @Test("A prefix match beats a match buried in the middle")
    func prefixBeatsMiddle() {
        let prefix = Matcher.score(query: "sto", candidate: "Store")!
        let middle = Matcher.score(query: "sto", candidate: "Apple Store Online")!
        #expect(prefix > middle)
    }

    @Test("A word-start match beats a mid-word one")
    func wordStartBonus() {
        let wordStart = Matcher.score(query: "tv", candidate: "Apple TV")!
        let midWord = Matcher.score(query: "tv", candidate: "Nativity")!
        #expect(wordStart > midWord)
    }

    @Test("Shorter labels win ties")
    func shorterWins() {
        let short = Matcher.score(query: "mac", candidate: "Mac")!
        let long = Matcher.score(query: "mac", candidate: "Mac accessories and more")!
        #expect(short > long)
    }

    @Test("An empty query keeps every target in its original order")
    func emptyQueryPassesThrough() {
        let targets = [makeTarget("one"), makeTarget("two"), makeTarget("three")]
        let filtered = Matcher.filter(targets, query: "  ")
        #expect(filtered.map(\.label) == ["one", "two", "three"])
    }

    @Test("filter drops non-matches and returns the best first")
    func filterOrders() {
        let targets = [
            makeTarget("AirPods"),
            makeTarget("Acquista"),
            makeTarget("Supporto"),
        ]
        let filtered = Matcher.filter(targets, query: "acq")
        #expect(filtered.first?.label == "Acquista")
        #expect(!filtered.contains { $0.label == "Supporto" })
    }

    @Test("The app name is searchable, not just the label")
    func searchesAppName() {
        let target = makeTarget("Untitled", appName: "Safari")
        #expect(Matcher.score(query: "safari", candidate: target.searchableText) != nil)
    }
}
