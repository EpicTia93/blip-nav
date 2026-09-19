import CoreGraphics
import Testing
@testable import BlipCore

/// The display layout these tests use, which is the one that breaks naive conversions:
/// a secondary display sitting above *and* to the left of the primary, so CG
/// coordinates there are negative on both axes.
private let primaryHeight: CGFloat = 1080

@Suite("Geometry")
struct GeometryTests {

    @Test("CG and AppKit rect conversions round-trip")
    func rectRoundTrip() {
        let original = CGRect(x: 120, y: 40, width: 200, height: 60)
        let appKit = Geometry.cgToAppKit(rect: original, primaryHeight: primaryHeight)
        let back = Geometry.appKitToCG(rect: appKit, primaryHeight: primaryHeight)
        #expect(back == original)
    }

    @Test("A rect at the top of the primary display maps to the top in AppKit space")
    func topOfScreen() {
        // 40pt from the top in CG, 60pt tall -> its bottom edge is 100pt from the top,
        // which is 1080 - 100 = 980 up from the AppKit origin.
        let rect = CGRect(x: 0, y: 40, width: 100, height: 60)
        let appKit = Geometry.cgToAppKit(rect: rect, primaryHeight: primaryHeight)
        #expect(appKit.origin.y == 980)
        #expect(appKit.height == 60)
    }

    @Test("A display above the primary yields AppKit coordinates beyond its top edge")
    func displayAbovePrimary() {
        // CG y = -400 means 400pt above the primary's top edge.
        let rect = CGRect(x: -1920, y: -400, width: 100, height: 50)
        let appKit = Geometry.cgToAppKit(rect: rect, primaryHeight: primaryHeight)
        let expectedY: CGFloat = 1080 + 400 - 50
        #expect(appKit.origin.y == expectedY)
        #expect(appKit.origin.x == CGFloat(-1920))
    }

    @Test("Point conversion is its own inverse")
    func pointRoundTrip() {
        let point = CGPoint(x: 33, y: 777)
        let appKit = Geometry.cgToAppKit(point: point, primaryHeight: primaryHeight)
        #expect(Geometry.appKitToCG(point: appKit, primaryHeight: primaryHeight) == point)
    }

    @Test("Vision's bottom-left normalised box maps to a top-left CG rect")
    func visionMapping() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 500)
        // Bottom-left corner of the image, one tenth of its size.
        let box = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let cg = Geometry.visionToCG(boundingBox: box, displayBounds: display)
        #expect(cg.origin.x == 0)
        // Bottom in Vision terms is the *high* Y end in CG terms.
        #expect(cg.origin.y == 450)
        #expect(cg.width == 100)
        #expect(cg.height == 50)
    }

    @Test("Vision mapping is offset by the display's own origin")
    func visionMappingOffsetDisplay() {
        let display = CGRect(x: -1920, y: -400, width: 1920, height: 1200)
        let box = CGRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25)
        let cg = Geometry.visionToCG(boundingBox: box, displayBounds: display)
        let expectedX: CGFloat = -1920 + 960
        let expectedY: CGFloat = -400 + 0.25 * 1200
        #expect(cg.origin.x == expectedX)
        #expect(cg.origin.y == expectedY)
    }

    @Test("IoU is 1 for identical rects and 0 for disjoint ones")
    func iouBounds() {
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(Geometry.iou(rect, rect) == 1)
        #expect(Geometry.iou(rect, CGRect(x: 100, y: 100, width: 10, height: 10)) == 0)
    }

    @Test("IoU of half-overlapping rects is one third")
    func iouPartial() {
        let a = CGRect(x: 0, y: 0, width: 10, height: 10)
        let b = CGRect(x: 5, y: 0, width: 10, height: 10)
        // intersection 50, union 150
        #expect(abs(Geometry.iou(a, b) - (1.0 / 3.0)) < 0.0001)
    }
}
