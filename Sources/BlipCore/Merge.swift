import CoreGraphics
import Foundation

/// Combines the Accessibility and OCR target sets into one list.
///
/// The two scanners overlap heavily — a button with a text label is seen by both — so
/// without this every such control would get two numbers sitting on top of each other.
/// Accessibility always wins a collision, because an AX element carries a real press
/// action while an OCR box can only ever be clicked at by synthesising a mouse event.
public enum Merge {

    /// Overlap above which an OCR box is considered to be describing the same thing as
    /// an AX element. Low enough to catch an OCR line that covers only the text inside
    /// a large button, high enough not to swallow a separate control sitting alongside.
    public static let overlapThreshold: CGFloat = 0.3

    /// Minimum edge length, in points, for an OCR box to be worth a hint. Vision
    /// happily returns slivers from gradients and icon edges.
    public static let minimumOCRSize: CGFloat = 6

    public static func combine(accessibility: [Target], ocr: [Target]) -> [Target] {
        guard !accessibility.isEmpty else { return ocr.filter(isWorthKeeping) }

        let surviving = ocr.filter { candidate in
            guard isWorthKeeping(candidate) else { return false }
            return !accessibility.contains { axTarget in
                isDuplicate(ocr: candidate, ax: axTarget)
            }
        }
        return accessibility + surviving
    }

    private static func isWorthKeeping(_ target: Target) -> Bool {
        guard target.frame.width >= minimumOCRSize,
              target.frame.height >= minimumOCRSize else { return false }
        return !target.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Two ways of being the same thing: substantial mutual overlap, or the OCR text
    /// sitting inside the AX element's frame (the common case, where Vision reads the
    /// word "Acquista" strictly within the bounds of the button that contains it).
    static func isDuplicate(ocr: Target, ax: Target) -> Bool {
        if Geometry.iou(ocr.frame, ax.frame) > overlapThreshold { return true }
        return ax.frame.contains(ocr.center)
    }
}
