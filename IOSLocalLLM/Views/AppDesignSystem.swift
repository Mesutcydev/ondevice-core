import SwiftUI

// MARK: - Shared semantic design tokens
//
// What remains here after the Studio consolidation. `StudioTokens` /
// `StudioSpacing` / `StudioRadius` are the app's design language; this file
// holds the few tokens that outlived the old system because they are still
// load-bearing for the Lens (camera) chrome, which has different constraints
// to the rest of the app — it composites over a live camera feed, so it needs
// a heavier material than any Studio surface.
//
// Removed with the landing screen: AppRadius, AssistantSpacing,
// AssistantRadius, AppStroke, AppShadow, AppTypography and
// KeyboardDismissModifier — all of them had zero remaining call sites.

enum AppSpacing {
    static let xSmall: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 16
    static let xLarge: CGFloat = 24
    static let xxLarge: CGFloat = 32
}

enum AppAnimation {
    static let quick = Animation.easeOut(duration: 0.18)
    static let state = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

/// Panel used by the Lens overlays, which composite over a live camera feed.
///
/// Instrument keeps ONE exception to the flat-fill rule, and this is it: over
/// a moving camera image an opaque panel is the only thing that stays legible,
/// so `cameraSafe` gets a near-opaque instrument fill rather than a material.
/// Everything else in the app resolves to a flat panel + hairline, square, no
/// shadow — same as every other surface.
struct AppPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = StudioRadius.panel
    var cameraSafe = false

    @Environment(\.koduTheme) private var T

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                // Over the camera the panel must own its pixels; elsewhere it
                // sits a single value off the page.
                shape.fill(cameraSafe ? T.bg.opacity(0.92) : T.surface)
            }
            .overlay {
                shape.stroke(cameraSafe ? T.rule2 : T.rule, lineWidth: 1)
            }
    }
}

extension View {
    func appPanel(cornerRadius: CGFloat = StudioRadius.panel, cameraSafe: Bool = false) -> some View {
        modifier(AppPanelBackground(cornerRadius: cornerRadius, cameraSafe: cameraSafe))
    }

    func minimumInteractiveSize() -> some View {
        frame(minWidth: 44, minHeight: 44)
    }
}
