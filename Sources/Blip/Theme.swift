import SwiftUI

/// Colours and metrics shared by the overlay.
///
/// The accent is taken from the logo's gradient, which runs from #FB246F at the top to
/// #76013A at the bottom; this is the mid-point, bright enough to stay visible against
/// both a white document and a dark terminal.
enum Theme {
    static let accent = Color(red: 0xFB / 255, green: 0x2E / 255, blue: 0x7E / 255)
    static let accentNSColor = NSColor(red: 0xFB / 255, green: 0x2E / 255, blue: 0x7E / 255, alpha: 1)

    /// Hint chip fill.
    static let hintFill = Color(red: 0xFD / 255, green: 0xEE / 255, blue: 0x88 / 255)
    /// OCR-derived chips are tinted apart from Accessibility ones, because they are
    /// clicked by coordinate rather than pressed, and behave differently when they fail.
    static let ocrHintFill = Color(red: 0x9E / 255, green: 0xDC / 255, blue: 0xFF / 255)

    static let hintText = Color.black
}

/// Layout constants for the search bar.
///
/// Shared rather than inlined because the connector line has to start exactly where the
/// bar is drawn, and the two drifting apart would be invisible in code and obvious on
/// screen.
enum OverlayMetrics {
    static let searchBarWidth: CGFloat = 520
    static let searchBarHeight: CGFloat = 46
    static let searchBarBottomInset: CGFloat = 80

    /// Point on the top edge of the search bar that the connector line leaves from.
    static func connectorOrigin(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2,
            y: size.height - searchBarBottomInset - searchBarHeight
        )
    }
}
