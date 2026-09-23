import SwiftUI
import OnDeviceUI
import UIKit   // resolves the concrete SF face names for the type helpers

// Compatibility names for host screens, backed by the current native palette.
// Persisted legacy appearance/accent values are retained for data compatibility.

// MARK: - Palette

struct KoduTheme {

    // Background layers
    let bg: Color           // page background
    let surface: Color      // cards
    let surface2: Color     // secondary surface (toolbars, code blocks)
    let surface3: Color     // tertiary surface

    // Text ink (4 levels of hierarchy)
    let ink: Color          // primary
    let ink2: Color         // secondary
    let ink3: Color         // tertiary / labels
    let ink4: Color         // disabled / very subtle

    // Borders
    let rule: Color         // hairline 8% black
    let rule2: Color        // stronger 16% black

    // Brand
    let accent: Color       // #1d4ed8
    let accentSoft: Color   // rgba(29,78,216,0.10)
    let accentSofter: Color // rgba(29,78,216,0.06)

    // Semantic
    let good: Color
    let warn: Color
    let bad: Color

    // Spacing (single scale to match the prototype's pad/gap idea)
    let pad: CGFloat
    let gap: CGFloat

    let isDark: Bool
    /// True for the OLED appearance, where `bg` is pure black. Raised surfaces read this so they lift just enough
    /// to register without pulling the page off true black.
    var isOLED: Bool = false

    // Brand-accent anchors. Stored (not computed) so `KoduTheme.make(appearance:accent:)`
    // can swap the whole brand-accent family per selected palette while leaving
    // backgrounds, ink, the sage `accent2`, and semantic good/warn/bad intact.
    // Defaults below reproduce the original Liquid Pink rose exactly.
    let roseHi: Color        // top of the primary-button gradient
    let roseDeep: Color      // inline code / deep edge of user bubble
    let accentStrong: Color  // primary CTA / active tab — deeper than `accent`

    /// Host compatibility tokens resolve directly to the current supplied native palette.
    static let light = native(isDark: false)
    static let dark = native(isDark: true)
    static let oled = native(isDark: true, isOLED: true)

    private static func native(isDark: Bool, isOLED: Bool = false) -> KoduTheme {
        KoduTheme(bg: isOLED ? .black : ODPalette.background, surface: ODPalette.surface,
                  surface2: ODPalette.input, surface3: ODPalette.chrome,
                  ink: ODPalette.text, ink2: ODPalette.secondary,
                  ink3: ODPalette.secondary, ink4: ODPalette.secondary,
                  rule: ODPalette.line, rule2: ODPalette.line,
                  accent: ODPalette.text, accentSoft: ODPalette.selected,
                  accentSofter: ODPalette.input,
                  good: ODPalette.text, warn: .orange, bad: ODPalette.red,
                  pad: ODLayout.pageInset, gap: ODLayout.elementGap,
                  isDark: isDark, isOLED: isOLED, roseHi: ODPalette.text,
                  roseDeep: ODPalette.text, accentStrong: ODPalette.send)
    }

    enum KoduAccent: String, CaseIterable, Identifiable, Sendable {
        // `onyx` is the app's default — a near-black graphite monochrome (the
        // professional, ChatGPT-like look: near-black primary actions, color
        // reserved for status). Listed first so it leads the Settings swatch
        // row. `system` (vivid iOS blue) and the rest stay selectable.
        // rawValues are persisted, so the order may change freely.
        case instrument, onyx, system, rose, blue, violet, emerald, amber, graphite, teal, indigo, coral, magenta
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .instrument: return "Instrument"
            case .onyx: return "Onyx"
            case .system: return "System"
            case .rose: return "Rose"
            case .blue: return "Blue"
            case .violet: return "Violet"
            case .emerald: return "Emerald"
            case .amber: return "Amber"
            case .graphite: return "Graphite"
            case .teal: return "Teal"
            case .indigo: return "Indigo"
            case .coral: return "Coral"
            case .magenta: return "Magenta"
            }
        }

        /// Representative accent color for the Settings swatch picker. `.rose`
        /// isn't in `anchors()` (make() returns the base theme for it), so it's
        /// resolved explicitly here.
        func swatchColor(dark: Bool) -> Color {
            if self == .rose {
                return dark ? Color(red: 1.0, green: 0.361, blue: 0.604)
                            : Color(red: 1.0, green: 0.180, blue: 0.494)
            }
            return anchors(dark: dark).accent
        }
        /// (accent, hi, deep, strong) anchors for this palette at the given appearance.
        fileprivate func anchors(dark: Bool) -> (accent: Color, hi: Color, deep: Color, strong: Color) {
            func c(_ r: Double, _ g: Double, _ b: Double) -> Color { Color(red: r, green: g, blue: b) }
            switch self {
            case .instrument:
                // Monochrome. There is no brand hue: "live" is pure white on
                // dark (17.9:1) and pure ink on light, one step brighter than
                // body text rather than a different colour from it. The only
                // hues left in the product are `warn` and `bad`, which means
                // anything coloured on screen is a condition, not decoration.
                //
                // This replaced a signal lime. The lime worked structurally —
                // it was unmistakably not an AI-app accent — but it read as
                // loud rather than expensive, and an instrument whose lamp is
                // lit at all times is not telling you anything.
                return dark
                    ? (c(1.000,1.000,1.000), c(1.000,1.000,1.000), c(0.659,0.682,0.714), c(0.910,0.918,0.929))
                    : (c(0.039,0.043,0.051), c(0.039,0.043,0.051), c(0.000,0.000,0.000), c(0.039,0.043,0.051))
            case .onyx:
                // Near-black graphite monochrome — the ChatGPT-like default.
                // Light: near-black accent/CTA (white text ~15:1). Dark: a
                // mid-graphite family kept dark enough that white button text
                // still passes everywhere (no light-on-light), while the accent
                // stays legible as ink on dark/OLED backgrounds.
                return dark
                    ? (c(0.46,0.46,0.51), c(0.55,0.55,0.60), c(0.36,0.36,0.41), c(0.42,0.42,0.47))
                    : (c(0.169,0.169,0.188), c(0.227,0.227,0.251), c(0.102,0.102,0.118), c(0.137,0.137,0.153))
            case .system:
                // iOS-native systemBlue — #007AFF (light) / a brighter blue for
                // dark. The clean, readable default: neutral page + white cards
                // + this accent reads like a stock iOS app. `hi` is kept no
                // lighter than the existing `.blue` palette's so white button
                // text holds the same contrast that already ships.
                return dark
                    ? (c(0.12,0.56,1.00), c(0.36,0.66,1.00), c(0.04,0.45,0.92), c(0.22,0.60,1.00))
                    : (c(0.00,0.478,1.00), c(0.20,0.56,1.00), c(0.00,0.33,0.78), c(0.00,0.40,0.90))
            case .rose:
                return dark
                    ? (c(1.000,0.361,0.604), c(1.000,0.561,0.694), c(1.000,0.180,0.494), c(1.000,0.302,0.553))
                    : (c(1.000,0.180,0.494), c(1.000,0.490,0.694), c(0.902,0.055,0.388), c(0.902,0.055,0.388))
            case .blue:
                return dark
                    ? (c(0.40,0.62,0.98), c(0.55,0.73,1.00), c(0.30,0.52,0.95), c(0.45,0.66,1.00))
                    : (c(0.23,0.51,0.92), c(0.36,0.62,0.97), c(0.13,0.36,0.75), c(0.18,0.44,0.84))
            case .violet:
                return dark
                    ? (c(0.66,0.52,0.95), c(0.74,0.62,1.00), c(0.56,0.42,0.92), c(0.70,0.56,1.00))
                    : (c(0.55,0.42,0.87), c(0.66,0.54,0.95), c(0.42,0.28,0.72), c(0.48,0.34,0.80))
            case .emerald:
                return dark
                    ? (c(0.30,0.80,0.58), c(0.42,0.88,0.66), c(0.22,0.70,0.50), c(0.34,0.82,0.60))
                    // Light `hi` darkened (was 0.24,0.72,0.53) so white hero
                    // text/eyebrows clear AA over the lightest gradient stop.
                    : (c(0.13,0.62,0.43), c(0.16,0.60,0.43), c(0.07,0.48,0.33), c(0.10,0.54,0.38))
            case .amber:
                return dark
                    ? (c(0.98,0.70,0.30), c(1.00,0.80,0.42), c(0.94,0.60,0.20), c(1.00,0.74,0.34))
                    // Light `hi`/`accent` darkened (was 0.86,0.53,0.13 / 0.95,
                    // 0.64,0.24) — the light orange failed AA under white text.
                    : (c(0.78,0.47,0.10), c(0.82,0.50,0.12), c(0.70,0.40,0.05), c(0.74,0.43,0.07))
            case .graphite:
                return dark
                    ? (c(0.62,0.66,0.72), c(0.74,0.78,0.84), c(0.50,0.54,0.60), c(0.70,0.74,0.80))
                    // Light `hi` darkened (was 0.48,0.52,0.58) for white-text AA.
                    : (c(0.36,0.40,0.46), c(0.40,0.44,0.50), c(0.24,0.28,0.34), c(0.30,0.34,0.40))
            case .teal:
                return dark
                    ? (c(0.20,0.78,0.74), c(0.34,0.86,0.82), c(0.12,0.68,0.64), c(0.26,0.80,0.76))
                    : (c(0.06,0.55,0.52), c(0.10,0.58,0.55), c(0.03,0.42,0.40), c(0.05,0.48,0.45))
            case .indigo:
                return dark
                    ? (c(0.48,0.52,0.96), c(0.60,0.63,1.00), c(0.40,0.44,0.92), c(0.52,0.56,1.00))
                    : (c(0.32,0.36,0.82), c(0.38,0.42,0.86), c(0.22,0.26,0.68), c(0.27,0.31,0.75))
            case .coral:
                return dark
                    ? (c(1.00,0.50,0.42), c(1.00,0.62,0.55), c(0.96,0.40,0.32), c(1.00,0.54,0.46))
                    : (c(0.88,0.30,0.22), c(0.90,0.34,0.26), c(0.74,0.20,0.14), c(0.80,0.24,0.17))
            case .magenta:
                return dark
                    ? (c(0.92,0.40,0.85), c(0.97,0.54,0.90), c(0.86,0.30,0.78), c(0.95,0.44,0.88))
                    : (c(0.78,0.16,0.66), c(0.82,0.22,0.70), c(0.64,0.08,0.54), c(0.72,0.12,0.60))
            }
        }
    }

    /// The only app-facing accent for now. Keeping the palette implementation
    /// below makes it easy to restore user-selectable colors later without
    /// allowing an old persisted choice to override the current black theme.
    static let appAccent: KoduAccent = .instrument

    /// Build a theme for an appearance + accent palette. `appearance` is the
    /// stored string — "light", "dark", or "oled". `.rose` is the untouched
    /// default; other palettes substitute only the brand-accent family.
    /// Applied at the root scene + tabs so the choice is app-wide.
    static func make(appearance: String, accent: KoduAccent) -> KoduTheme {
        native(isDark: appearance != "light", isOLED: appearance == "oled")
    }

    // MARK: - Liquid Pink extras
    //
    // These extra colors aren't exposed via the original struct so existing
    // views keep their identical layout. New glass views read them via the
    // static accessors below.

    var accentStrongSoft: Color {
        accentStrong.opacity(isDark ? 0.18 : 0.12)
    }
    /// Label/glyph color for content sitting ON an accent-family fill
    /// (`accent`, `roseHi`, `accentStrong`). The native palette renders those
    /// fills as near-black ink in light and near-white in dark, so the
    /// contrasting label must flip with the appearance — hard-coded `.white`
    /// is unreadable in dark mode (2026-09-21 device report: discovery
    /// catalog "download" capsule). `ODPalette.onSend` is exactly that pair.
    var onAccentFill: Color { ODPalette.onSend }
    /// Secondary neutral accent used for quiet supporting glyphs.
    var accent2: Color { ODPalette.secondary }
    /// Soft sage — fill for glyph tiles and pills that use `accent2`.
    var accent2Soft: Color {
        accent2.opacity(isDark ? 0.20 : 0.16)
    }

    // MARK: - Per-category model tints (Models hub)
    //
    // Each of the four model roles gets its own hue so cards are colour-coded
    // by type at a glance. Assistant uses the rose `accent`, Lens the sage
    // `accent2`; voice and image get the two below. Kept distinct from the
    // semantic `warn` amber so a "tight"/cleanup warning never reads as an
    // image card.

    /// Voice role — violet.
    var voiceTint: Color { ODPalette.secondary }
    var voiceTintSoft: Color { voiceTint.opacity(isDark ? 0.20 : 0.14) }

    /// Image role — warm amber/orange (distinct from the cooler `warn`).
    var imageTint: Color { ODPalette.secondary }
    var imageTintSoft: Color { imageTint.opacity(isDark ? 0.20 : 0.14) }
    /// Subtle border used by legacy glass call sites.
    var glassBorder: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }
    /// Legacy inset color retained for compatibility with existing modifiers.
    var glassShadowInset: Color {
        isDark ? Color.black.opacity(0.20) : Color.black.opacity(0.03)
    }

    // MARK: - Typography helpers
    //
    // The app is set in SF Pro / SF Mono. These helpers exist for one reason:
    // to get an ARBITRARY point size that still follows Dynamic Type.
    //
    // The sans face used to be built with
    // `Font.custom(sansFace, size: size, relativeTo: .body)`, where `sansFace`
    // was cached from `UIFont.systemFont(ofSize: 17).fontName`. That call
    // reports a PRIVATE name (".SFUI-Regular"), and CoreText cannot
    // re-instantiate a dot-prefixed system face by name. Every one of those
    // calls therefore fell through to the last-resort face — **Times New
    // Roman** — at every size, in every label, everywhere in the app.
    //
    // That is measured, not inferred: at 20pt the string "Probe text 123"
    // rendered 113.3pt wide through `sans(20)` and 113.3pt through
    // `.custom("Times New Roman", 20)`, with identical ink height, against
    // 122.7pt for `.system(size: 20)`. `Font.system(size:weight:)` is both the
    // correct face and Dynamic-Type aware — the same string re-measured at
    // Accessibility Extra Large was 251.3pt through `sans` and 346.0pt through
    // `.system(size:)` — so it is used directly.
    //
    // Rule: never address an SF face by name. `.system(...)` or a real family.

    /// The system serif (New York). Resolved per call through the `.serif`
    /// design descriptor rather than a single baked-in face name, so each
    /// requested weight maps to the matching New York cut instead of
    /// synthesizing every weight from one. On iOS this resolves to the real
    /// New York faces; the fallback in `serif(_:)` covers any platform where
    /// the serif design is unavailable. An unresolvable custom face does NOT
    /// fall back to sans — it falls back to Times, which is how the sans
    /// helpers above shipped a serif app — hence the explicit `design: .serif`
    /// fallback here.
    static func serifFontName(weight: UIFont.Weight) -> String? {
        let base = UIFont.systemFont(ofSize: 17, weight: weight)
        // `withDesign` is the only failable step; the descriptor initializer
        // itself is non-failable and always yields a usable face.
        guard let desc = base.fontDescriptor.withDesign(.serif) else { return nil }
        return UIFont(descriptor: desc, size: 17).fontName
    }

    /// Display / sans body at an arbitrary size, scaling with Dynamic Type.
    private func semantic(_ size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<14: return .footnote
        case ..<16: return .subheadline
        case ..<19: return .body
        case ..<23: return .title3
        case ..<28: return .title2
        case ..<33: return .title
        default: return .largeTitle
        }
    }
    func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(semantic(size)).weight(weight)
    }
    var conversationBody: Font { .body }
    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(semantic(size)).weight(weight)
    }
    func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(semantic(size)).weight(weight)
    }
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(semantic(size)).weight(weight)
    }

}

// MARK: - Dynamic Type modifier

extension View {
    /// Semantic typography follows the full system Dynamic Type range.
    func koduScaledType() -> some View {
        self
    }
}

// MARK: - Environment

private struct KoduThemeKey: EnvironmentKey {
    static let defaultValue: KoduTheme = .dark
}

extension EnvironmentValues {
    var koduTheme: KoduTheme {
        get { self[KoduThemeKey.self] }
        set { self[KoduThemeKey.self] = newValue }
    }
}

extension View {
    /// Inject a KoduTheme into the environment.
    func koduTheme(_ theme: KoduTheme) -> some View {
        modifier(NativeThemeEnvironment())
    }
}

private struct NativeThemeEnvironment: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        content.environment(\.koduTheme, colorScheme == .dark ? .dark : .light)
    }
}
