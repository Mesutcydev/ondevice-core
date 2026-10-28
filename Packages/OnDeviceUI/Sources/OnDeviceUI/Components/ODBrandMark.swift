import SwiftUI

/// The Token stepped waveform, traced from the 1024-pt app icon master as a
/// centerline so it strokes crisply at any size. Bounds include the stroke.
struct ODBrandMarkShape: Shape {
    static let size = CGSize(width: 704, height: 234)
    static let stroke: CGFloat = 37
    private static let points: [CGPoint] = [
        (0, 183.5), (85.5, 183.5), (85.5, 125.5), (171.5, 125.5), (171.5, 215.5),
        (257.5, 215.5), (257.5, 146.5), (342.5, 146.5), (342.5, 66.5), (428.5, 66.5),
        (428.5, 194.5), (514.5, 194.5), (514.5, 18.5), (600.5, 18.5), (600.5, 157.5),
        (685.5, 157.5), (685.5, 109),
    ].map { CGPoint(x: $0.0, y: $0.1) }

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / Self.size.width, sy = rect.height / Self.size.height
        var path = Path()
        path.addLines(Self.points.map { CGPoint(x: rect.minX + $0.x * sx, y: rect.minY + $0.y * sy) })
        return path
    }
}

/// The brand mark in the current foreground style.
/// `.drawOn` traces it once on appear; `.live` streams a highlight along the
/// steps for model activity, replacing generic spinners and dots; `.intro`
/// traces it, then keeps streaming (splash and onboarding).
public struct ODBrandMark: View {
    public enum Motion: Sendable { case still, drawOn, live, intro }

    private let height: CGFloat
    private let motion: Motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @State private var drawn: CGFloat = 0
    @State private var streamStart: Date?

    public init(height: CGFloat = 16, motion: Motion = .still) {
        self.height = height
        self.motion = motion
    }

    public var body: some View {
        let shape = ODBrandMarkShape()
        let style = StrokeStyle(lineWidth: height * ODBrandMarkShape.stroke / ODBrandMarkShape.size.height,
                                lineCap: .butt, lineJoin: .miter)
        Group {
            switch motion {
            case .still:
                shape.stroke(style: style)
            case .drawOn, .intro:
                shape.trim(from: 0, to: reduceMotion ? 1 : drawn).stroke(style: style)
                    .opacity(streamStart == nil ? 1 : 0.25)
                    .overlay { if let streamStart { stream(shape, style, from: streamStart) } }
                    .onAppear {
                        withAnimation(.easeOut(duration: 0.8)) { drawn = 1 } completion: {
                            guard motion == .intro, !reduceMotion else { return }
                            withAnimation(.easeInOut(duration: 0.3)) { streamStart = .now }
                        }
                    }
            case .live:
                shape.stroke(style: style).opacity(reduceMotion ? 0.6 : 0.2)
                    .overlay { if !reduceMotion { stream(shape, style, from: .distantPast) } }
            }
        }
        .frame(width: height * ODBrandMarkShape.size.width / ODBrandMarkShape.size.height, height: height)
        .accessibilityHidden(true)
    }

    /// A 30% window enters at the left and leaves at the right every 1.4 s.
    private func stream(_ shape: ODBrandMarkShape, _ style: StrokeStyle, from start: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || !workspaceVisible || scenePhase != .active)) { context in
            let t = context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: 1.4) / 1.4 * 1.3
            shape.trim(from: max(0, t - 0.3), to: min(1, t)).stroke(style: style)
        }
    }
}

/// The app icon in miniature: white mark on the icon's ink plate.
public struct ODBrandTile: View {
    private let size: CGFloat
    private let motion: ODBrandMark.Motion

    public init(size: CGFloat = 32, motion: ODBrandMark.Motion = .still) {
        self.size = size
        self.motion = motion
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Color(red: 0.043, green: 0.047, blue: 0.063))
            // Keeps the plate's edge visible on dark and OLED canvases.
            .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            .overlay {
                // Icon proportions: the mark spans 69% of the width, 2% above center.
                ODBrandMark(height: size * 0.2285, motion: motion)
                    .foregroundStyle(.white)
                    .offset(y: -size * 0.023)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
