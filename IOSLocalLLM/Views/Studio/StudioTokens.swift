import SwiftUI
import OnDeviceUI

// Compatibility names for host views. All presentation values follow OnDeviceUI.
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
    var userTurnFill: Color { ODPalette.input }
    var scrim: Color { Color.black.opacity(0.34) }

    var surfaceRaised: Color { ODPalette.surface }
    var strokeRest: Color { ODPalette.line }
    var strokeFocus: Color { ODPalette.text }
    var shadowAmbient: Color { .clear }
    var shadowKey: Color { .clear }

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

    /// Editorial serif — the rarest face. Proper names only: model names,
    /// voice names, session titles. See `KoduTheme.serif`.
    func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        theme.serif(size, weight)
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
    // 24, not 26: the scale is 4pt-derived end to end; 26 was the one
    // off-grid value left in it.
    static let xxl: CGFloat = 24

    /// End-of-list breathing room for a scrolling tab page.
    ///
    /// This was 140pt of run-out, written when the app mounted its own bar as a
    /// bottom `safeAreaInset` and a page had to clear it by hand. The shell is a
    /// native `TabView` now, and a native bar *is* reserved in the scroll view's
    /// inset — measured at ~82pt above the screen edge on an iPhone 17 — so the
    /// 140 left a third of a screen of empty paper after the last row. Same
    /// value as the package's `ODSpace.tabBarRunout`, so a page cannot be short
    /// or long by accident.
    static let tabBarClearance: CGFloat = 24
}

/// App-owned content corners. Native controls retain their OS geometry.
enum StudioRadius {
    static let spine: CGFloat = 12
    static let panel: CGFloat = 20
    static let small: CGFloat = 8
    static let tile: CGFloat = 12
    static let chip: CGFloat = 12
    static let glyph: CGFloat = 12
    static let action: CGFloat = 20
    static let send: CGFloat = 24
    static let sheet: CGFloat = 24
    static let badge: CGFloat = 8
    static let composer: CGFloat = 24
}

// MARK: - Motion

/// The app's four motion roles.
///
/// Durations were literals in every file that needed one — 0.1, 0.18, 0.25,
/// 0.55, 1.5, 1.6 — which is exactly how a design system drifts: the same
/// gesture ends up with three different curves depending on which file it was
/// written in. Four roles, named after what the motion *means*, not how long
/// it takes.
///
/// Ambient motion (`breathe`, `sweep`) must be gated on Reduce Motion by the
/// caller — see `studioAnimation(_:value:)`, which does it for you. A slower
/// pulse is still a pulse.
enum StudioMotion {
    /// A press, a toggle, a filter switching. Must land before the finger
    /// lifts or it reads as lag rather than feedback.
    static let tap = Animation.easeOut(duration: 0.12)

    /// A value updating in place, a row revealing, a meter refilling. The
    /// workhorse — most of the app's motion is this one.
    static let state = Animation.easeOut(duration: 0.22)

    /// Content arriving on screen. The only curve in the system with
    /// overshoot; that slight settle is what separates "appeared" from
    /// "materialised".
    static let entrance = Animation.spring(response: 0.40, dampingFraction: 0.80)

    /// A lit indicator at rest. Slow enough to read as breathing rather than
    /// blinking.
    static func breathe(_ period: Double = 1.5) -> Animation {
        .easeInOut(duration: period).repeatForever(autoreverses: true)
    }

    /// A pass that says "still running" between discrete updates — the
    /// difference between a stalled runtime and a working one when the
    /// numbers happen to be identical for a second.
    static func sweep(_ period: Double = 1.6) -> Animation {
        .linear(duration: period).repeatForever(autoreverses: false)
    }

    /// Delay for the nth item in a staggered entrance. Capped, so a long list
    /// does not take a second and a half to finish arriving.
    static func stagger(_ index: Int, step: Double = 0.035, cap: Double = 0.28) -> Double {
        min(Double(max(index, 0)) * step, cap)
    }
}

/// `.animation` that yields to Reduce Motion.
///
/// The accessibility setting means "no motion", not "less motion", so this
/// drops to `nil` rather than substituting a gentler curve.
private struct StudioAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation?
    let value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// Animate `value` changes with `animation`, unless the user has asked
    /// for Reduce Motion. Prefer this over a bare `.animation` anywhere the
    /// motion is decorative rather than essential to understanding the state.
    func studioAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(StudioAnimationModifier(animation: animation, value: value))
    }
}

// MARK: - Primitives

/// The app's single press feedback: the control dims, it does not move.
///
/// This used to scale to 0.93 on press. Nothing in an instrument shrinks when
/// you touch it — the readout changes, the panel does not — and the app was
/// running two press languages at once: 11 controls scaled, 4 dimmed. One
/// language, and it is the one that leaves the geometry alone.
struct StudioPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Alias kept so the Instrument components read in their own vocabulary.
/// Identical behaviour by construction rather than by copy — two structs with
/// the same body is how a design system drifts.
typealias InstrumentPressStyle = StudioPressStyle

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

/// Native actions shared by secondary host screens.
struct StudioPrimaryButton: View {
    let title: String
    var height: CGFloat = 44
    var radius: CGFloat = 12
    let action: () -> Void
    var body: some View {
        Button(title, action: action)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.glassProminent)
            .odInkProminent()
            .controlSize(.large)
    }
}

struct StudioSecondaryButton: View {
    let title: String
    var height: CGFloat = 44
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: ODLayout.elementGap) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.body).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass).controlSize(.large)
        .foregroundStyle(ODPalette.text)
    }
}

struct StudioOutlineButton: View {
    let title: String
    var height: CGFloat = 44
    let action: () -> Void
    var body: some View {
        StudioSecondaryButton(title: title, action: action)
    }
}

struct StudioDangerButton: View {
    let title: String
    var height: CGFloat = 44
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: ODLayout.elementGap) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.body).frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.glass).controlSize(.large)
        .tint(ODPalette.red)
    }
}

struct StudioCompactPrimaryButton: View {
    let title: String
    var symbol: String? = nil
    var enabled = true
    var height: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: ODLayout.elementGap) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.footnote).frame(minHeight: 44)
        }
        .buttonStyle(.glassProminent)
        .odInkProminent()
        .disabled(!enabled)
    }
}

struct StudioCompactSecondaryButton: View {
    let title: String
    var symbol: String? = nil
    var destructive = false
    var enabled = true
    var height: CGFloat = 44
    let action: () -> Void
    var body: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            HStack(spacing: ODLayout.elementGap) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.footnote).frame(minHeight: 44)
        }
        .buttonStyle(.glass)
        .tint(destructive ? ODPalette.red : ODPalette.text)
        .disabled(!enabled)
    }
}

struct StudioSquareToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch)
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
        Text(text)
            .font(.footnote)
            .foregroundStyle(color ?? T.studio.ink3)
    }
}
