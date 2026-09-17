import SwiftUI
import UIKit   // resolves the concrete SF face names for the type helpers

// MARK: - KoduTheme
//
// The app's single source of colour and type. Three appearances (light, dark,
// OLED) and a brand-accent family, injected at the root and read everywhere via
// `@Environment(\.koduTheme)`. `StudioTokens` is a view onto this, not a
// second palette.
//
// Neutral content, hairline boundaries, colour reserved for state or the one
// primary action on a screen. Set in SF Pro / SF Mono — an earlier revision
// specified Geist, but no font files were ever added to the target, so the
// helpers below resolve the system faces and say so.
//
// Usage:
//   @Environment(\.koduTheme) var T
//   Text("hello").font(T.mono(11)).foregroundColor(T.ink2)

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
    /// True for the pure-black OLED appearance, where `bg` is #010102 rather
    /// than a near-black. Raised surfaces read this so they lift just enough
    /// to register without pulling the page off true black.
    var isOLED: Bool = false

    // Brand-accent anchors. Stored (not computed) so `KoduTheme.make(appearance:accent:)`
    // can swap the whole brand-accent family per selected palette while leaving
    // backgrounds, ink, the sage `accent2`, and semantic good/warn/bad intact.
    // Defaults below reproduce the original Liquid Pink rose exactly.
    let roseHi: Color        // top of the primary-button gradient
    let roseDeep: Color      // inline code / deep edge of user bubble
    let accentStrong: Color  // primary CTA / active tab — deeper than `accent`

    // MARK: - Light — original white tone (no cream)
    static let light = KoduTheme(
        bg:        Color(hex: 0xF7F9FD),                          // original pearl-white canvas
        surface:   Color(hex: 0x1C1C1E).opacity(0.04),            // quiet panel tint
        surface2:  Color(hex: 0x1C1C1E).opacity(0.07),            // raised tint
        surface3:  Color(hex: 0x1C1C1E).opacity(0.03),            // whisper tint
        ink:       Color(hex: 0x1C1C1E),
        ink2:      Color(hex: 0x6D6D72),
        ink3:      Color(hex: 0x5A5A5F),                          // glyphs / mono metrics (4.5:1 floor)
        ink4:      Color(hex: 0xC7C7CC),                          // placeholders and chevrons only
        rule:      Color(hex: 0x1C1C1E).opacity(0.10),
        rule2:     Color(hex: 0x1C1C1E).opacity(0.14),
        accent:    Color(hex: 0x1F5E46),                          // sage, state only
        accentSoft:   Color(hex: 0x1F5E46).opacity(0.10),
        accentSofter: Color(hex: 0x1F5E46).opacity(0.06),
        good:      Color(hex: 0x1F5E46),
        warn:      Color(hex: 0x8A6116),
        bad:       Color(hex: 0xA8352C),
        pad: 16, gap: 10,
        isDark: false,
        roseHi:       Color(hex: 0x2F7A5C),
        roseDeep:     Color(hex: 0x17452F),
        accentStrong: Color(hex: 0x1C1C1E)
    )

    // MARK: - Dark — neutral ink
    static let dark = KoduTheme(
        // The dark appearance inverts the white-tone palette: ink becomes the
        // page, paper becomes the text, rules lift to warm-neutral white.
        bg:        Color(hex: 0x151517),
        surface:   Color(hex: 0xF5F6F8).opacity(0.06),
        surface2:  Color(hex: 0xF5F6F8).opacity(0.10),
        surface3:  Color(hex: 0xF5F6F8).opacity(0.04),
        ink:       Color(hex: 0xF5F6F8),
        ink2:      Color(hex: 0xB4B4B9),
        ink3:      Color(hex: 0xA0A0A5),
        ink4:      Color(hex: 0x6F6F74),
        rule:      Color(hex: 0xF5F6F8).opacity(0.10),
        rule2:     Color(hex: 0xF5F6F8).opacity(0.16),
        accent:    Color(hex: 0x8FBFA8),
        accentSoft:   Color(hex: 0x8FBFA8).opacity(0.14),
        accentSofter: Color(hex: 0x8FBFA8).opacity(0.08),
        good:      Color(hex: 0x8FBFA8),
        warn:      Color(hex: 0xD9A75F),
        bad:       Color(hex: 0xE2836F),
        pad: 16, gap: 10,
        isDark: true,
        roseHi:       Color(hex: 0xA8CFBB),
        roseDeep:     Color(hex: 0x5F8F76),
        accentStrong: Color(hex: 0x8FBFA8)
    )

    // MARK: - OLED Dark — Plum Dusk
    //
    // Pure #000000 page so OLED pixels switch off (deeper blacks, less battery),
    // with NEUTRAL grays for ink/surfaces instead of the warm mulberry of the
    // standard dark theme — the readable, high-contrast look of a modern code
    // editor. Surfaces are translucent whites over the black page, so cards/
    // pills read as subtly elevated panels (≈#121212 / #212121) rather than
    // pure black, keeping depth without lifting the page off true black.
    static let oled = KoduTheme(
        bg:        Color(red: 0.004, green: 0.004, blue: 0.008),  // #010102 OLED black
        surface:   Color.white.opacity(0.10),                     // clear elevated card
        surface2:  Color.white.opacity(0.15),                     // clear glass highlight
        surface3:  Color.white.opacity(0.06),                     // quiet glass layer
        ink:       Color(red: 0.929, green: 0.929, blue: 0.937),  // #EDEDEF off-white (not harsh pure white)
        ink2:      Color(red: 0.706, green: 0.706, blue: 0.729),  // #B4B4BA secondary
        ink3:      Color(red: 0.510, green: 0.510, blue: 0.533),  // #828288 tertiary
        ink4:      Color(red: 0.337, green: 0.337, blue: 0.357),  // #56565B quaternary
        rule:      Color.white.opacity(0.09),
        rule2:     Color.white.opacity(0.16),
        accent:    Color(red: 0.769, green: 0.169, blue: 0.522),  // #C42B85
        accentSoft:   Color(red: 0.643, green: 0.067, blue: 0.384).opacity(0.30),
        accentSofter: Color(red: 0.643, green: 0.067, blue: 0.384).opacity(0.16),
        good:      Color(red: 0.525, green: 1.000, blue: 0.753),  // #86FFC0
        warn:      Color(red: 0.988, green: 0.827, blue: 0.302),  // #FCD34D
        bad:       Color(red: 0.988, green: 0.647, blue: 0.647),  // #FCA5A5
        pad: 16, gap: 10,
        isDark: true,
        isOLED: true,
        roseHi:       Color(red: 0.635, green: 0.071, blue: 0.400), // #A21266
        roseDeep:     Color(red: 0.431, green: 0.043, blue: 0.275), // #6E0B46
        accentStrong: Color(red: 0.431, green: 0.043, blue: 0.275)
    )

    // MARK: - Accent palettes (theme combinations)
    //
    // Each palette swaps ONLY the brand-accent family (accent + soft/softer +
    // hi/deep/strong). Backgrounds, ink, the sage `accent2`, and good/warn/bad
    // are untouched, so layout and the semantic color language don't change.
    // `.rose` returns the original Liquid Pink theme byte-for-byte.
    enum KoduAccent: String, CaseIterable, Identifiable, Sendable {
        // `onyx` is the app's default — a near-black graphite monochrome (the
        // professional, ChatGPT-like look: near-black primary actions, color
        // reserved for status). Listed first so it leads the Settings swatch
        // row. `system` (vivid iOS blue) and the rest stay selectable.
        // rawValues are persisted, so the order may change freely.
        case onyx, system, rose, blue, violet, emerald, amber, graphite, teal, indigo, coral, magenta
        var id: String { rawValue }
        var displayName: String {
            switch self {
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
    static let appAccent: KoduAccent = .onyx

    /// Build a theme for an appearance + accent palette. `appearance` is the
    /// stored string — "light", "dark", or "oled". `.rose` is the untouched
    /// default; other palettes substitute only the brand-accent family.
    /// Applied at the root scene + tabs so the choice is app-wide.
    static func make(appearance: String, accent: KoduAccent) -> KoduTheme {
        let base: KoduTheme
        switch appearance {
        case "oled": base = .oled
        case "dark": base = .dark
        default:     base = .light
        }
        let dark = base.isDark
        if accent == .rose { return base }
        let a = accent.anchors(dark: dark)
        return KoduTheme(
            bg: base.bg, surface: base.surface, surface2: base.surface2, surface3: base.surface3,
            ink: base.ink, ink2: base.ink2, ink3: base.ink3, ink4: base.ink4,
            rule: base.rule, rule2: base.rule2,
            accent: a.accent,
            accentSoft: a.accent.opacity(dark ? 0.18 : 0.14),
            accentSofter: a.accent.opacity(dark ? 0.10 : 0.07),
            good: base.good, warn: base.warn, bad: base.bad,
            pad: base.pad, gap: base.gap,
            isDark: base.isDark,
            isOLED: base.isOLED,
            roseHi: a.hi, roseDeep: a.deep, accentStrong: a.strong
        )
    }

    // MARK: - Liquid Pink extras
    //
    // These extra colors aren't exposed via the original struct so existing
    // views keep their identical layout. New glass views read them via the
    // static accessors below.

    var accentStrongSoft: Color {
        accentStrong.opacity(isDark ? 0.18 : 0.12)
    }
    /// Secondary neutral accent used for quiet supporting glyphs.
    var accent2: Color {
        isDark
            ? Color(red: 0.620, green: 0.650, blue: 0.700)
            : Color(red: 0.430, green: 0.460, blue: 0.520)
    }
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
    var voiceTint: Color {
        isDark
            ? Color(red: 0.745, green: 0.624, blue: 1.000)   // #BE9FFF
            : Color(red: 0.553, green: 0.420, blue: 0.871)   // #8D6BDE
    }
    var voiceTintSoft: Color { voiceTint.opacity(isDark ? 0.20 : 0.14) }

    /// Image role — warm amber/orange (distinct from the cooler `warn`).
    var imageTint: Color {
        isDark
            ? Color(red: 1.000, green: 0.722, blue: 0.404)   // #FFB867
            : Color(red: 0.910, green: 0.561, blue: 0.180)   // #E88F2E
    }
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
    // `.font(.system(size: 17))` is a fixed size — it ignores the user's text
    // size entirely. `Font.custom(_:size:relativeTo:)` is the only way to ask
    // for "17pt, but scale it like body text does", so every helper below
    // routes through it. Prefer these over `.system(size:)` for anything the
    // user reads.
    //
    // These previously probed for a bundled "Geist" family first. No Geist
    // files were ever added to the target and `UIAppFonts` is absent from
    // Info.plist, so every call had always fallen through to the system face —
    // the lookup, its cache and its weight-name mapping were dead code
    // describing a design intent that did not ship.

    /// Cached system face names. `UIFont.systemFont(...).fontName` resolves to
    /// the concrete SF face (e.g. ".SFUI-Regular"); it does not change at
    /// runtime, so resolving it once avoids a UIFont construction per call.
    nonisolated(unsafe) private static let sansFace: String =
        UIFont.systemFont(ofSize: 17).fontName
    nonisolated(unsafe) private static let monoFace: String =
        UIFont.monospacedSystemFont(ofSize: 17, weight: .regular).fontName

    /// Display / sans body at an arbitrary size, scaling with Dynamic Type.
    func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        Font.custom(Self.sansFace, size: size, relativeTo: .body).weight(weight)
    }

    /// Shared reading size for prompts, live responses, and completed transcripts.
    var conversationBody: Font { .body }

    func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom(Self.sansFace, size: size, relativeTo: .body).weight(weight)
    }

    /// Monospaced — pervasive in this design language, used for every machine
    /// fact (metrics, byte counts, model ids).
    func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font.custom(Self.monoFace, size: size, relativeTo: .body).weight(weight)
    }
}

// MARK: - Dynamic Type modifier

extension View {
    /// Limits how aggressively a view scales with iOS Larger Text settings.
    /// We allow up to `.accessibility2` so the design doesn't blow up.
    func koduScaledType() -> some View {
        self.dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }
}

// MARK: - Environment

private struct KoduThemeKey: EnvironmentKey {
    static let defaultValue: KoduTheme = .light
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
        self.environment(\.koduTheme, theme)
    }
}
