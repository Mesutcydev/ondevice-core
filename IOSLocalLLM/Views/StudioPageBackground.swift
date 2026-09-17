import SwiftUI

// MARK: - Studio page background
//
// The app's single page surface: one flat colour from the theme, nothing else.
// It was called `LiquidPinkBackdrop` and drew blurred pink blooms; the Studio
// language replaced those with a flat page and hairlines, but the old name
// survived across 49 call sites and described something that no longer
// existed. Renamed so the type says what it does.

struct StudioPageBackground: View {
    @Environment(\.koduTheme) private var T

    var body: some View {
        T.studio.paper
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

// MARK: - Card / pill primitives — removed
//
// `LiquidGlassCard`, `LiquidGlassPill` and `LiquidGlassIconButton` were
// deleted with zero call sites (verified by grep across app + tests +
// packages). Their surfaces are expressed directly through `kGlass` /
// `kClearGlass` at the remaining call sites, which now render the Studio
// flat-fill + hairline pair.

// MARK: - Active badge
struct KActivePinkBadge: View {
    @Environment(\.koduTheme) private var T
    let text: String

    init(_ text: String = "ACTIVE") { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(T.mono(9, .semibold))
            .tracking(0.4)
            .foregroundColor(T.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: StudioRadius.spine, style: .continuous)
                    .stroke(T.rule, lineWidth: 1)
            )
    }
}
