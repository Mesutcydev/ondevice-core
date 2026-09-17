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

/// Camera-safe panel used by the Lens overlays. Deliberately heavier than a
/// Studio surface: `.regularMaterial` and a brighter stroke, because a thin
/// material over a live camera feed reads as a smudge rather than a panel.
struct AppPanelBackground: ViewModifier {
    var cornerRadius: CGFloat = StudioRadius.panel
    var cameraSafe = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if reduceTransparency {
                    shape.fill(cameraSafe ? Color(uiColor: .secondarySystemBackground) : Color(uiColor: .systemBackground))
                } else {
                    shape.fill(cameraSafe ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.thinMaterial))
                }
            }
            .overlay {
                shape.stroke(
                    cameraSafe
                        ? Color.white.opacity(colorScheme == .dark ? 0.22 : 0.34)
                        : Color.primary.opacity(0.10),
                    lineWidth: 0.5
                )
            }
            .shadow(color: Color.black.opacity(0.16), radius: 18, y: 6)
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
