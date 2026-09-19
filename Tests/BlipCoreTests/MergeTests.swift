import CoreGraphics
import Testing
@testable import BlipCore

@Suite("Merge and Occlusion")
struct MergeTests {

    @Test("An OCR box sitting inside an AX button is dropped as a duplicate")
    func ocrInsideAXIsDropped() {
        let button = makeTarget("Acquista", x: 100, y: 100, width: 120, height: 40)
        // Vision reads just the word, strictly within the button's bounds.
        let text = makeTarget("Acquista", x: 120, y: 112, width: 80, height: 16, source: .ocr)
        let merged = Merge.combine(accessibility: [button], ocr: [text])
        #expect(merged.count == 1)
        #expect(merged.first?.source == .accessibility)
    }

    @Test("An OCR box away from any AX element survives")
    func ocrElsewhereSurvives() {
        let button = makeTarget("Acquista", x: 100, y: 100, width: 120, height: 40)
        let canvasText = makeTarget("Layer 3", x: 600, y: 400, width: 80, height: 16, source: .ocr)
        let merged = Merge.combine(accessibility: [button], ocr: [canvasText])
        #expect(merged.count == 2)
    }

    @Test("With no AX elements at all, OCR carries the whole result")
    func ocrOnlyPassesThrough() {
        let text = makeTarget("Render", x: 10, y: 10, width: 60, height: 16, source: .ocr)
        #expect(Merge.combine(accessibility: [], ocr: [text]).count == 1)
    }

    @Test("Slivers and blank OCR results are discarded")
    func discardsNoise() {
        let sliver = makeTarget("x", x: 0, y: 0, width: 200, height: 2, source: .ocr)
        let blank = makeTarget("   ", x: 0, y: 50, width: 60, height: 16, source: .ocr)
        #expect(Merge.combine(accessibility: [], ocr: [sliver, blank]).isEmpty)
    }

    @Test("An element under a covering window is not visible")
    func occludedElementHidden() {
        let front = makeWindow(id: 1, x: 0, y: 0, width: 800, height: 600, zIndex: 0)
        let back = makeWindow(id: 2, x: 0, y: 0, width: 800, height: 600, zIndex: 1)
        let hidden = makeTarget("behind", x: 100, y: 100, windowID: 2, zIndex: 1)
        let visible = Occlusion.filterVisible([hidden], windows: [front, back])
        #expect(visible.isEmpty)
    }

    @Test("An element in the exposed part of a background window stays visible")
    func exposedElementKept() {
        // The front window only covers the left half of the screen.
        let front = makeWindow(id: 1, x: 0, y: 0, width: 400, height: 600, zIndex: 0)
        let back = makeWindow(id: 2, x: 0, y: 0, width: 800, height: 600, zIndex: 1)
        let exposed = makeTarget("right side", x: 600, y: 100, windowID: 2, zIndex: 1)
        #expect(Occlusion.filterVisible([exposed], windows: [front, back]).count == 1)
    }

    @Test("A window never occludes its own contents")
    func windowDoesNotOccludeItself() {
        let window = makeWindow(id: 1, zIndex: 0)
        let target = makeTarget("mine", x: 100, y: 100, windowID: 1, zIndex: 0)
        #expect(Occlusion.filterVisible([target], windows: [window]).count == 1)
    }

    @Test("OCR targets bypass occlusion, having been read off the composited screen")
    func ocrBypassesOcclusion() {
        let front = makeWindow(id: 1, zIndex: 0)
        let back = makeWindow(id: 2, zIndex: 1)
        let ocr = makeTarget("seen", x: 100, y: 100, source: .ocr, windowID: nil, zIndex: 1)
        #expect(Occlusion.filterVisible([ocr], windows: [front, back]).count == 1)
    }
}

@Suite("Whole-window occlusion culling")
struct WindowCullingTests {

    @Test("A window identically stacked behind another is fully occluded")
    func identicalStackIsCulled() {
        let front = makeWindow(id: 1, zIndex: 0)
        let back = makeWindow(id: 2, zIndex: 1)
        #expect(Occlusion.isFullyOccluded(back, by: [front, back]))
    }

    @Test("The frontmost window is never occluded")
    func frontmostSurvives() {
        let front = makeWindow(id: 1, zIndex: 0)
        let back = makeWindow(id: 2, zIndex: 1)
        #expect(!Occlusion.isFullyOccluded(front, by: [front, back]))
    }

    @Test("A partially covered window is not culled")
    func partialCoverSurvives() {
        let front = makeWindow(id: 1, width: 400, zIndex: 0)
        let back = makeWindow(id: 2, width: 800, zIndex: 1)
        #expect(!Occlusion.isFullyOccluded(back, by: [front, back]))
    }

    @Test("Several partial windows can together bury one completely")
    func combinedCoverCulls() {
        // Two half-width windows in front that between them span the whole of the back
        // one. Neither covers it alone, so this only works if the subtraction
        // accumulates across windows.
        let left = makeWindow(id: 1, x: 0, width: 400, zIndex: 0)
        let right = makeWindow(id: 2, x: 400, width: 400, zIndex: 1)
        let back = makeWindow(id: 3, x: 0, width: 800, zIndex: 2)
        #expect(Occlusion.isFullyOccluded(back, by: [left, right, back]))
    }

    @Test("A window on another display is untouched by one on the primary")
    func separateDisplaysDoNotOcclude() {
        let onPrimary = makeWindow(id: 1, x: 0, width: 800, zIndex: 0)
        let onSecondary = makeWindow(id: 2, x: -1920, width: 800, zIndex: 1)
        #expect(!Occlusion.isFullyOccluded(onSecondary, by: [onPrimary, onSecondary]))
    }

    @Test("Subtracting a covering rect leaves nothing")
    func subtractFullCover() {
        let rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        #expect(Occlusion.subtract(CGRect(x: 0, y: 0, width: 100, height: 100), from: rect).isEmpty)
    }

    @Test("Subtracting a disjoint rect leaves the original")
    func subtractDisjoint() {
        let rect = CGRect(x: 0, y: 0, width: 50, height: 50)
        let pieces = Occlusion.subtract(CGRect(x: 200, y: 200, width: 10, height: 10), from: rect)
        #expect(pieces == [rect])
    }

    @Test("Subtracting a centred hole leaves four disjoint strips of the right area")
    func subtractCentreLeavesStrips() {
        let rect = CGRect(x: 0, y: 0, width: 30, height: 30)
        let pieces = Occlusion.subtract(CGRect(x: 10, y: 10, width: 10, height: 10), from: rect)
        #expect(pieces.count == 4)
        // 900 total minus the 100 removed; the strips must not double-count.
        let area = pieces.reduce(0) { $0 + $1.width * $1.height }
        #expect(area == 800)
    }
}
