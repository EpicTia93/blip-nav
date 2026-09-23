import AppKit
import BlipCore
import BlipKit
import SwiftUI

/// The heads-up display: a hint chip on every target, plus the search bar and, while
/// filtering, a connector line to the match Enter would take -- which Tab moves.
///
/// One instance per screen. Each only draws the targets whose centre falls on its own
/// screen, and only the active screen draws the search bar.
struct OverlayView: View {
    @ObservedObject var state: OverlayState
    let screenCGBounds: CGRect
    let showsSearchBar: Bool
    let configuration: Configuration

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // A fully transparent hit-free backdrop. No dimming: the overlay is a
                // heads-up layer over work the user is still reading, and darkening it
                // made the underlying app harder to use, not the hints easier to see.
                Color.clear

                if showsSearchBar, state.hasPointer, let match = state.topMatch,
                   let end = localCenter(of: match) {
                    ConnectorLine(
                        from: OverlayMetrics.connectorOrigin(in: proxy.size),
                        to: end
                    )
                    TargetHighlight(rect: localRect(of: match))
                }

                ForEach(chips, id: \.target.id) { chip in
                    HintChip(
                        text: chip.target.hint ?? "",
                        matchedPrefix: state.digitPrefix,
                        fontSize: configuration.hintFontSize,
                        isOCR: chip.target.source == .ocr,
                        isTopMatch: chip.isTopMatch
                    )
                    .offset(x: chip.position.x, y: chip.position.y)
                }

                if showsSearchBar {
                    VStack(spacing: 8) {
                        SearchBar(state: state)
                        if let notice = state.notice {
                            Text(notice)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, OverlayMetrics.searchBarBottomInset)
                }
            }
        }
        // The hosting view must not try to be clever about safe areas: the panel covers
        // the entire display including under the menu bar and Dock.
        .ignoresSafeArea()
    }

    // MARK: - Layout

    private struct Chip {
        var target: Target
        var position: CGPoint
        var isTopMatch: Bool
    }

    private func localRect(of target: Target) -> CGRect {
        CGRect(
            x: target.frame.origin.x - screenCGBounds.origin.x,
            y: target.frame.origin.y - screenCGBounds.origin.y,
            width: target.frame.width,
            height: target.frame.height
        )
    }

    /// Centre of a target in this screen's local space, or nil when it is on another
    /// display — the connector must not be drawn to a point off this panel.
    private func localCenter(of target: Target) -> CGPoint? {
        let centre = CGPoint(x: target.frame.midX, y: target.frame.midY)
        guard screenCGBounds.contains(centre) else { return nil }
        return CGPoint(
            x: centre.x - screenCGBounds.origin.x,
            y: centre.y - screenCGBounds.origin.y
        )
    }

    /// Targets on this screen, positioned in the view's local (top-left, Y-down) space.
    private var chips: [Chip] {
        let visibleIDs = Set(state.visibleTargets.map(\.id))
        let topMatchID = state.topMatch?.id
        // Once digits are being typed, hide everything they cannot lead to. That turns
        // the overlay from a wall of numbers into a shortlist as the user commits.
        let prefix = state.digitPrefix

        return state.allTargets.compactMap { target -> Chip? in
            guard visibleIDs.contains(target.id) else { return nil }
            if !prefix.isEmpty, !(target.hint ?? "").hasPrefix(prefix) { return nil }
            guard screenCGBounds.contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
            else { return nil }

            let local = localRect(of: target)
            // Sit the chip just above the target's top-left corner, the way Vimium
            // does, clamped so chips on the top row stay on screen.
            let y = max(0, local.minY - configuration.hintFontSize * 0.6)
            return Chip(
                target: target,
                position: CGPoint(x: max(0, local.minX), y: y),
                isTopMatch: target.id == topMatchID && state.hasPointer
            )
        }
    }
}

/// Line from the search bar to the match Enter would activate.
///
/// Borrowed from Superkey, and it earns its place: with a query narrowing dozens of
/// hints, the one Enter will take is otherwise indistinguishable from the rest, and it
/// may be at the far edge of a different window.
private struct ConnectorLine: View {
    let from: CGPoint
    let to: CGPoint

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            Theme.accent.opacity(0.85),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
        .shadow(color: .black.opacity(0.35), radius: 1)
        .allowsHitTesting(false)
    }
}

/// Ring around the target the connector points at.
private struct TargetHighlight: View {
    let rect: CGRect

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(Theme.accent, lineWidth: 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Theme.accent.opacity(0.18))
            )
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

/// A single numbered chip.
private struct HintChip: View {
    let text: String
    let matchedPrefix: String
    let fontSize: Double
    let isOCR: Bool
    let isTopMatch: Bool

    var body: some View {
        HStack(spacing: 0) {
            // The already-typed digits are shown dimmed so the eye jumps to what is
            // still left to type.
            if !matchedPrefix.isEmpty, text.hasPrefix(matchedPrefix) {
                Text(matchedPrefix).foregroundStyle(Theme.hintText.opacity(0.35))
                Text(text.dropFirst(matchedPrefix.count)).foregroundStyle(Theme.hintText)
            } else {
                Text(text).foregroundStyle(Theme.hintText)
            }
        }
        .font(.system(size: fontSize, weight: .bold, design: .rounded))
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(isOCR ? Theme.ocrHintFill : Theme.hintFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(
                    isTopMatch ? Theme.accent : .black.opacity(0.45),
                    lineWidth: isTopMatch ? 1.5 : 0.5
                )
        )
        // Flatten first: a bare .shadow() is a style that each leaf primitive draws
        // for itself, which puts a blurry halo around the digits as well as the chip.
        .compositingGroup()
        .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
        .fixedSize()
    }
}

/// The query field. Drawn text, not a control: the panel never takes focus, so there is
/// nothing for a real text field to be focused in.
private struct SearchBar: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.accent)

            // Laid out in a single row so the caret sits *after* the typed text and
            // *before* the placeholder, instead of being drawn on top of it.
            HStack(spacing: 1) {
                if !state.query.isEmpty {
                    Text(state.query)
                        .foregroundStyle(Theme.searchBarText)
                }
                Caret()
                if state.query.isEmpty {
                    Text("Type to filter, or a number to jump")
                        .foregroundStyle(Theme.searchBarPlaceholder)
                }
            }
            .font(.system(size: 15, weight: .regular, design: .rounded))

            Spacer(minLength: 12)

            if state.isScanningOCR {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }

            // Tab is only useful while something is left to step to, and it is not a
            // key anyone would guess at, so say so exactly when it applies.
            if state.visibleTargets.count > 1, !state.query.isEmpty {
                Text("\u{21E5}")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(state.selectionID == nil ? Theme.accent.opacity(0.4) : Theme.accent)
            }

            Text("\(state.visibleTargets.count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.searchBarSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .frame(width: OverlayMetrics.searchBarWidth, height: OverlayMetrics.searchBarHeight)
        .background(Theme.searchBarFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, y: 8)
    }
}

private struct Caret: View {
    @State private var isVisible = true

    var body: some View {
        Rectangle()
            .fill(Theme.accent)
            .frame(width: 1.5, height: 17)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    isVisible = false
                }
            }
    }
}
