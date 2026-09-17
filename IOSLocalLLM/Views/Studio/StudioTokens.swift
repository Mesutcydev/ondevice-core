import SwiftUI

// MARK: - StudioTokens
//
// Token layer for the composer/chat rethink, wired into the app's existing
// `koduTheme` so the design follows the user's appearance setting. The
// palette (paper / ink / hairlines / sage accent) maps onto the theme's own
// sans/mono faces: light mode keeps the app's original pearl-white tone
// (no warm cast), and dark mode inverts it to a neutral near-black page with
// paper-toned text, rules at 10-16% white, and the sage accent tint.

struct StudioTokens {
    let theme: KoduTheme

    // MARK: Colors
    //
    // Every value below is DERIVED from the injected KoduTheme. It used to
    // re-declare the palette as literals, which silently pinned the whole
    // composer/chat surface to the light+dark pair: the OLED appearance kept
    // rendering a #151517 slab against a #010102 page, and all twelve accent
    // palettes were ignored in favour of a hardcoded sage. Reading the theme
    // is what makes those settings actually reach this surface.

    var paper: Color { theme.bg }
    var ink: Color { theme.ink }
    var ink2: Color { theme.ink2 }
    /// Glyph buttons, mono metrics, small labels.
    var ink3: Color { theme.ink3 }
    /// Placeholders and chevrons only.
    var ink4: Color { theme.ink4 }
    var chevron: Color { theme.ink4 }
    var accent: Color { theme.accent }
    var accentSoft: Color { theme.accentSoft }
    /// The deeper end of the accent family — filled primary actions.
    var accentStrong: Color { theme.accentStrong }
    var danger: Color { theme.bad }

    var rule: Color { theme.rule }
    var rule2: Color { theme.rule2 }
    var fillActive: Color { theme.ink.opacity(theme.isDark ? 0.08 : 0.06) }
    var userTurnFill: Color { theme.ink.opacity(theme.isDark ? 0.06 : 0.055) }
    var scrim: Color { Color.black.opacity(0.34) }

    // MARK: Elevation
    //
    // The composer is a contained surface, so it needs a fill that reads as
    // lifted ABOVE `paper` plus a boundary and a shadow. Light mode lifts to
    // pure white; dark lifts a step off the page; OLED lifts just enough to
    // register as a surface without pulling the page off true black.

    var surfaceRaised: Color {
        if theme.isOLED { return Color(hex: 0x141416) }
        return theme.isDark ? Color(hex: 0x1F1F22) : .white
    }
    /// Resting boundary of a raised surface — slightly stronger than a `rule`
    /// so the container edge survives against a busy thread behind it.
    var strokeRest: Color { theme.ink.opacity(theme.isDark ? 0.14 : 0.10) }
    /// Focused boundary — the accent, at a weight that reads as attention
    /// rather than as a validation error.
    var strokeFocus: Color { theme.accent.opacity(theme.isDark ? 0.55 : 0.42) }

    /// Wide, soft, barely-there — the ambient occlusion under a raised panel.
    var shadowAmbient: Color { Color.black.opacity(theme.isDark ? 0.34 : 0.07) }
    /// Tight contact shadow directly beneath the panel edge.
    var shadowKey: Color { Color.black.opacity(theme.isDark ? 0.28 : 0.05) }

    // Code blocks stay dark in both appearances so code reads as code.
    var codeBg: Color {
        theme.isDark ? Color(hex: 0x1D1D1F) : Color(hex: 0x1C1C1E)
    }
    var codeInk: Color { Color(hex: 0xE9E9EC) }
    var codeIdent: Color { Color(hex: 0x8FBFA8) }
    var codeKeyword: Color { Color(hex: 0xC9A3F5) }

    // MARK: Typography

    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        theme.sans(size, weight)
    }

    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        theme.mono(size, weight)
    }
}

extension KoduTheme {
    /// The composer/chat design language, resolved for the current appearance.
    var studio: StudioTokens { StudioTokens(theme: self) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

// MARK: - Scale

/// Spacing in points. 2, 4, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, 26, 30.
enum StudioSpacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 26
}

/// Radii in points. Nothing is a pill — never 9999.
///
/// Six values, no more: 3 · 6 · 10 · 14 · 20 · 26. The app had accumulated
/// nineteen distinct radii, which is the main reason nothing looked like it
/// belonged to the same product. The semantic names are kept so call sites
/// read by intent (and so this consolidation touches no other file); several
/// of them deliberately resolve to the same number.
enum StudioRadius {
    /// The clipped edge on a spined block. Nearly square by design.
    static let spine: CGFloat = 3
    static let small: CGFloat = 6
    static let chip: CGFloat = 10
    static let tile: CGFloat = 10
    static let glyph: CGFloat = 10
    static let action: CGFloat = 14
    static let send: CGFloat = 14
    /// Contained surfaces: the composer, cards that carry their own elevation.
    static let panel: CGFloat = 20
    static let sheet: CGFloat = 26
}

// MARK: - Primitives

/// Press feedback for filled controls: a small, fast inset. Distinct from
/// `.plain`, which gives no feedback at all, and from `.borderless`, which
/// dims the label instead of moving it.
struct StudioPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The single 1px boundary that separates composer, nav and sheet headers
/// from content. Defaults to the studio `rule` colour.
struct StudioHairline: View {
    var color: Color? = nil

    @Environment(\.koduTheme) private var T

    var body: some View {
        Rectangle()
            .fill(color ?? T.studio.rule)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// 34pt square-cut glyph button. No fill at rest — that is the whole point.
///
/// The visible chip stays `size` (34 by default), but the button is laid out
/// in a 44pt box so the tap target meets the HIG minimum. Drawing and hit
/// testing were previously the same 34pt frame, which made every glyph in the
/// composer and the answer action row a sub-minimum target.
struct StudioGlyphButton: View {
    let symbol: String
    var active = false
    var size: CGFloat = 34
    var weight: Font.Weight = .medium
    var glyphSize: CGFloat = 15
    let action: () -> Void

    @Environment(\.koduTheme) private var T

    /// Apple's minimum comfortable target.
    static let minimumTarget: CGFloat = 44

    /// How far the visible chip is inset inside its tap box at the default
    /// size. A row of these needs this much NEGATIVE leading padding to keep
    /// its first glyph optically flush with text above it.
    static let opticalInset: CGFloat = (minimumTarget - 34) / 2

    var body: some View {
        let S = T.studio
        Button {
            HapticManager.impact(.light)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: weight))
                .foregroundStyle(active ? S.ink : S.ink3)
                .frame(width: size, height: size)
                .background(
                    active ? S.fillActive : .clear,
                    in: RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                )
                .frame(minWidth: Self.minimumTarget, minHeight: Self.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(StudioPressStyle())
    }
}

/// The one filled button per screen.
struct StudioPrimaryButton: View {
    let title: String
    var height: CGFloat = 44
    var radius: CGFloat = StudioRadius.action
    let action: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        Button(action: action) {
            Text(title)
                .font(S.sans(15.5, .medium))
                .foregroundStyle(S.paper)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(S.ink, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(StudioPressStyle())
    }
}

/// Outlined secondary — a border, never a fill, never a pill.
struct StudioOutlineButton: View {
    let title: String
    var height: CGFloat = 44
    let action: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        Button(action: action) {
            Text(title)
                .font(S.sans(14.5, .medium))
                .foregroundStyle(S.ink)
                .frame(maxWidth: .infinity, minHeight: height)
                .overlay(
                    RoundedRectangle(cornerRadius: StudioRadius.action, style: .continuous)
                        .stroke(S.ink.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Square-cut switch: 48x29, radius 8, knob 23 radius 6.
struct StudioSquareToggle: View {
    @Binding var isOn: Bool

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        Button {
            withAnimation(.easeOut(duration: 0.16)) { isOn.toggle() }
            HapticManager.impact(.light)
        } label: {
            RoundedRectangle(cornerRadius: StudioRadius.tile, style: .continuous)
                .fill(isOn ? S.accent : S.ink.opacity(0.13))
                .frame(width: 48, height: 29)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white)
                        .frame(width: 23, height: 23)
                        .padding(.horizontal, 3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Mono micro-label for every machine fact in the design. Uppercased,
/// letter-spaced; defaults to the studio `ink3`.
struct StudioMonoLabel: View {
    let text: String
    var size: CGFloat = 11
    var tracking: CGFloat = 0.8
    var color: Color? = nil

    @Environment(\.koduTheme) private var T

    var body: some View {
        Text(text.uppercased())
            .font(T.studio.mono(size))
            .tracking(tracking)
            .foregroundStyle(color ?? T.studio.ink3)
    }
}
