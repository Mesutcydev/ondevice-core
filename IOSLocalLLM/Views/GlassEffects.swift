import SwiftUI

// MARK: - Centralized surface renderer (Studio)
//
// Historical names (`glassSurface`, `kGlass`, `kClearGlass`) are retained for
// source compatibility, but the Studio design language replaced every glass
// material with flat fills and 1px hairlines: no blur, no refraction, no
// shadow. The renderer below is the single surface primitive the whole app
// still routes through, so the reskin is performed here once.

/// Three roles, because three are used. This carried nine — `hero`,
/// `listRow`, `icon`, `badge`, `toolbarButton` and `tabBar` had zero call
/// sites, and two of the dead ones were the last `999` pill radii in the
/// codebase.
enum GlassRole {
    case card, button, capsule

    /// Default radius, used only when a caller does not supply its own.
    /// `kGlass` and the shape-based helpers always do, so in practice this
    /// applies to bare `glassSurface(.card)`.
    var radius: CGFloat {
        switch self {
        case .card: StudioRadius.panel
        case .button: StudioRadius.action
        case .capsule: StudioRadius.chip
        }
    }

    /// Interactive surfaces get a resting fill; static ones stay transparent
    /// and are defined by their hairline alone.
    var interactive: Bool {
        switch self {
        case .button, .capsule: true
        case .card: false
        }
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: GlassRole
    let cornerRadius: CGFloat?

    @Environment(\.koduTheme) private var T

    func body(content: Content) -> some View {
        let radius = cornerRadius ?? role.radius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(role.interactive ? T.studio.fillActive : T.surface, in: shape)
            .overlay(shape.stroke(T.studio.rule, lineWidth: 1))
    }
}

extension View {
    func glassSurface(
        _ role: GlassRole = .card,
        cornerRadius: CGFloat? = nil
    ) -> some View {
        modifier(GlassSurfaceModifier(role: role, cornerRadius: cornerRadius))
    }
}

// MARK: - Accessible material

extension ShapeStyle where Self == AnyShapeStyle {
    /// The opaque panel fill, for every user.
    ///
    /// This used to return `.ultraThinMaterial` unless Reduce Transparency was
    /// on. Instrument has no blur: a material is depth, and there is no z-axis
    /// here. It now returns `opaque` in both branches, which also means the
    /// accessibility setting no longer changes what anyone sees — everyone
    /// gets the legible version rather than only the users who asked for it.
    ///
    /// The parameter is retained because four call sites pass it, and the
    /// `ShapeStyle` shape is retained because two of them use it as a `fill`
    /// rather than a `background`.
    static func adaptiveMaterial(reduceTransparency: Bool,
                                 opaque: Color) -> AnyShapeStyle {
        AnyShapeStyle(opaque)
    }
}

// MARK: - Compatibility helpers
// Existing call sites route into the renderer above. Fill/stroke hints that
// callers already provide become the flat surface; without hints the renderer
// falls back to the studio fill/hairline pair.

extension View {
    /// Flat chip/button surface. (Historical name — this was Liquid Glass;
    /// the Studio language renders a flat fill plus a 1px hairline.)
    @ViewBuilder
    func kClearGlass<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: shape,
            role: interactive ? .button : .capsule,
            fill: fallbackFill,
            stroke: fallbackStroke,
            tint: tint
        ))
    }

    /// Flat card surface with a hairline. (Historical name.)
    @ViewBuilder
    func kGlass(
        cornerRadius: CGFloat = StudioRadius.tile,
        tint: Color? = nil,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            role: .card,
            fill: fallbackFill,
            stroke: fallbackStroke,
            tint: tint
        ))
    }

    /// Historical name: it passes `role: .capsule` for the resting fill but
    /// draws the chip radius, not a `Capsule()`. Kept for call-site
    /// compatibility; if you want a true capsule, pass the shape explicitly.
    @ViewBuilder
    func kGlassCapsule(
        tint: Color? = nil,
        fallbackFill: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        modifier(ShapeGlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous),
            role: .capsule,
            fill: fallbackFill,
            stroke: fallbackStroke,
            tint: tint
        ))
    }
}

private struct ShapeGlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let role: GlassRole
    let fill: Color
    let stroke: Color
    /// Surface tint. This used to be accepted and silently dropped — the
    /// renderer's fill resolution never read it, so every tinted surface
    /// (`KActivePill`, `KSection(tinted:)`, `LiquidGlassPill(active:)`)
    /// rendered untinted. Tint now composites OVER the role's resting fill
    /// so interactive roles keep their base tone beneath the tint.
    let tint: Color?

    @Environment(\.koduTheme) private var T

    func body(content: Content) -> some View {
        let restingFill: Color = fill != .clear
            ? fill
            : (role.interactive ? T.studio.fillActive : .clear)
        let resolvedFill: Color = tint ?? restingFill
        let resolvedStroke: Color = stroke != .clear ? stroke : T.studio.rule
        content
            .background(resolvedFill, in: shape)
            .overlay(shape.stroke(resolvedStroke, lineWidth: 1))
    }
}

// MARK: - Container

/// Wraps a group of glass elements so iOS can morph them as one shape during
/// transitions. No-op pre-iOS 26.
struct KGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

// MARK: - Shimmer
//
// Gradient sweep that animates across a view to indicate "loading" or
// "the model is thinking". Used on:
//   • streaming assistant bubbles before tokens arrive
//   • search result placeholders while a network query is in flight
//   • model card skeletons during catalog resolve
//
// Implementation: a moving angular highlight masked by the host view's
// shape, drawn with `.blendMode(.softLight)` so it lights the underlying
// surface instead of recoloring it. The phase is driven by a single
// @State on the modifier; we deliberately animate offset (not opacity)
// because offset animation is GPU-cheap and runs on the compositor.

extension View {
    /// Adds a shimmering highlight that travels across `self` while
    /// `isActive` is true. No-op when false (and stops cleanly).
    ///
    /// `intensity` (0...1) controls the brightness of the sweep; default
    /// 0.55 reads as a soft material highlight rather than a flashy
    /// "skeleton screen" effect.
    func shimmer(
        isActive: Bool = true,
        duration: Double = 1.4,
        intensity: Double = 0.55
    ) -> some View {
        modifier(ShimmerModifier(isActive: isActive, duration: duration, intensity: intensity))
    }
}

private struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    let duration: Double
    let intensity: Double

    @Environment(\.koduTheme) private var T
    @State private var phase: CGFloat = -1.0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geo in
                        let width = geo.size.width
                        // Width of the highlight band relative to the host.
                        // 0.65 lets the band feel like a deliberate sweep
                        // rather than a thin streak (which can read as a
                        // rendering glitch on small surfaces).
                        let bandWidth = width * 0.65
                        // A lime scan pass, not a white specular sheen. The
                        // sweep still reports "this surface is working"; it
                        // just does it in the signal colour under a normal
                        // blend instead of imitating light on glass.
                        LinearGradient(
                            stops: [
                                .init(color: .clear,                        location: 0.0),
                                .init(color: T.accent.opacity(intensity),   location: 0.5),
                                .init(color: .clear,                        location: 1.0),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: bandWidth)
                        // Phase goes -1 → 1; multiply by (width + bandWidth)
                        // so the band fully clears the host on both sides.
                        // Without this, on narrow surfaces the band's tail
                        // would still be visible at the wrap point and the
                        // loop would read as a snap.
                        .offset(x: phase * (width + bandWidth))
                    }
                    .allowsHitTesting(false)
                }
            }
            .mask(content)
            .onAppear {
                guard isActive else { return }
                withAnimation(
                    .linear(duration: duration).repeatForever(autoreverses: false)
                ) { phase = 1.0 }
            }
            .onChange(of: isActive) { _, nowActive in
                if nowActive {
                    phase = -1.0
                    withAnimation(
                        .linear(duration: duration).repeatForever(autoreverses: false)
                    ) { phase = 1.0 }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) { phase = -1.0 }
                }
            }
    }
}
