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

    /// Search bar fill. Flat black, and opaque: a system material let whatever is
    /// behind the bar bleed through and tint it grey, which both muddied the accent
    /// query text and made the bar read as a panel rather than a heads-up field.
    static let searchBarFill = Color.black
    /// The typed query, drawn in the same accent as the pointer it is steering.
    static let searchBarText = accent
    /// The placeholder has to read as a hint, not as typed text, while still carrying
    /// against the dark fill -- so it is dimmed white rather than a dimmed accent.
    static let searchBarPlaceholder = Color.white.opacity(0.72)
    /// Match count and other trailing furniture: present, but behind the query.
    static let searchBarSecondary = Color.white.opacity(0.5)
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
