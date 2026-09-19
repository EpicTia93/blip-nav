import CoreGraphics
import Testing
@testable import BlipCore

@Suite("HintLabels")
struct HintLabelsTests {

    @Test("Numbers run left to right within a row, then down")
    func readingOrder() {
        let targets = [
            makeTarget("bottom-left", x: 0, y: 200),
            makeTarget("top-right", x: 300, y: 0),
            makeTarget("top-left", x: 0, y: 0),
        ]
        let assigned = HintLabels.assign(targets)
        let byLabel = Dictionary(uniqueKeysWithValues: assigned.map { ($0.label, $0.hint) })
        #expect(byLabel["top-left"] == "1")
        #expect(byLabel["top-right"] == "2")
        #expect(byLabel["bottom-left"] == "3")
    }

    @Test("Rows are banded, so a few points of vertical jitter does not zig-zag")
    func rowBanding() {
        // A toolbar whose items differ by 2pt vertically must still read left-to-right.
        let targets = [
            makeTarget("right", x: 300, y: 2),
            makeTarget("left", x: 0, y: 0),
        ]
        let assigned = HintLabels.assign(targets)
        #expect(assigned.first { $0.label == "left" }?.hint == "1")
        #expect(assigned.first { $0.label == "right" }?.hint == "2")
    }

    @Test("Frontmost window is numbered before windows behind it")
    func frontWindowFirst() {
        let targets = [
            makeTarget("behind", x: 0, y: 0, zIndex: 3),
            makeTarget("in front", x: 500, y: 500, zIndex: 0),
        ]
        let assigned = HintLabels.assign(targets)
        #expect(assigned.first { $0.label == "in front" }?.hint == "1")
        #expect(assigned.first { $0.label == "behind" }?.hint == "2")
    }

    @Test("An unextendable prefix fires immediately")
    func unambiguousPrefixFires() {
        // Three targets -> numbers 1, 2, 3. Nothing starts with "3" but 3 itself.
        let targets = HintLabels.assign((0..<3).map { makeTarget("t\($0)", y: CGFloat($0) * 30) })
        let third = targets.first { $0.hint == "3" }!
        #expect(HintLabels.resolve(prefix: "3", in: targets) == .exact(third.id))
    }

    @Test("A prefix that other numbers extend waits, but remembers its exact match")
    func ambiguousPrefixWaits() {
        // Twelve targets -> "1" is a valid number but "10", "11", "12" extend it.
        let targets = HintLabels.assign((0..<12).map { makeTarget("t\($0)", y: CGFloat($0) * 30) })
        let first = targets.first { $0.hint == "1" }!
        #expect(HintLabels.resolve(prefix: "1", in: targets) == .pending(exactMatch: first.id))
    }

    @Test("A prefix no number starts with is a dead end")
    func deadEndPrefix() {
        let targets = HintLabels.assign((0..<3).map { makeTarget("t\($0)", y: CGFloat($0) * 30) })
        #expect(HintLabels.resolve(prefix: "9", in: targets) == .none)
    }

    @Test("Growing an ambiguous prefix resolves it")
    func growingPrefixResolves() {
        let targets = HintLabels.assign((0..<12).map { makeTarget("t\($0)", y: CGFloat($0) * 30) })
        let twelfth = targets.first { $0.hint == "12" }!
        #expect(HintLabels.resolve(prefix: "12", in: targets) == .exact(twelfth.id))
    }
}
