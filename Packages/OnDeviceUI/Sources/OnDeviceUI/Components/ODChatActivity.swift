import SwiftUI

/// Shared chat activity surfaces. The host supplies real events and timestamps.
public struct ODToolEvent: Identifiable, Equatable {
    public enum Status: String, Equatable { case running, success, failure, cancelled }
    public let id: UUID
    public var title: String
    public var detail: String
    public var status: Status

    public init(id: UUID = UUID(), title: String, detail: String = "", status: Status) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

public struct ODAgentLabel: View {
    public init() {}
    public var body: some View {
        Text("AGENT", bundle: .module)
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(ODPalette.secondary)
            .accessibilityLabel(Text("Assistant", bundle: .module))
    }
}

/// The existing reply bar, shared by answer text and live reasoning.
public struct ODStreamingCaret: View {
    public let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @ScaledMetric(relativeTo: .body) private var caretHeight: CGFloat = 16

    public init(color: Color = ODPalette.text) { self.color = color }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15,
                                paused: reduceMotion || !workspaceVisible || scenePhase != .active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.2
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 2, height: caretHeight)
                .opacity(reduceMotion ? 0.65 : 0.35 + 0.65 * (sin(phase) + 1) / 2)
        }
        .accessibilityHidden(true)
    }
}

/// Lightweight streaming layout; only the caret animates between token updates.
public struct ODStreamingText: View {
    public let content: String
    public let font: Font
    public let color: Color
    public let lineSpacing: CGFloat

    public init(content: String, font: Font = .body, color: Color = ODPalette.text, lineSpacing: CGFloat = 4) {
        self.content = content
        self.font = font
        self.color = color
        self.lineSpacing = lineSpacing
    }

    public var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(content)
                .font(font)
                .foregroundStyle(color)
                .lineSpacing(lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.disabled)
            ODStreamingCaret(color: color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Streaming", bundle: .module))
        .accessibilityIdentifier("chat.reply.streaming")
    }
}

public struct ODToolPillStrip: View {
    public let events: [ODToolEvent]
    @State private var selectedEvent: ODToolEvent?
    @ScaledMetric(relativeTo: .caption2) private var titleMaximumWidth = 210
    public init(events: [ODToolEvent]) { self.events = events }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(events) { event in
                    Button { selectedEvent = event } label: {
                        HStack(spacing: 6) {
                            statusIcon(event.status)
                            Text(event.title)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(ODPalette.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: titleMaximumWidth, alignment: .leading)
                        }
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(ODPalette.input, in: Capsule())
                        .overlay { Capsule().strokeBorder(ODPalette.line, lineWidth: 1) }
                        .fixedSize()
                        .frame(minHeight: ODLayout.minimumHit)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(event.title)
                    .accessibilityValue(event.status.rawValue)
                    .accessibilityHint(Text("Shows tool details", bundle: .module))
                    .accessibilityIdentifier("chat.tool.\(event.id.uuidString)")
                }
            }
        }
        .frame(minHeight: ODLayout.minimumHit)
        .accessibilityIdentifier("chat.tools")
        .sheet(item: $selectedEvent) { event in
            NavigationStack {
                ScrollView {
                    Text(event.detail.isEmpty ? event.title : event.detail)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("chat.tool.details")
                }
                .navigationTitle(event.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { selectedEvent = nil } label: { Text("Done", bundle: .module) }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private func statusIcon(_ status: ODToolEvent.Status) -> some View {
        switch status {
        case .running:
            ProgressView().controlSize(.mini).accessibilityHidden(true)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.20, green: 0.78, blue: 0.59)).accessibilityHidden(true)
        case .failure:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.red).accessibilityHidden(true)
        case .cancelled:
            Image(systemName: "minus.circle.fill").foregroundStyle(ODPalette.secondary).accessibilityHidden(true)
        }
    }
}

/// Only this small view redraws for the dots; transcript text is not re-laid out.
public struct ODActivityDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: reduceMotion || !workspaceVisible || scenePhase != .active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    let wave = reduceMotion ? 0 : max(0, sin(time * .pi * 2 - Double(index) * 0.9))
                    Circle()
                        .fill(ODPalette.secondary)
                        .frame(width: 6, height: 6)
                        .offset(y: -3 * wave)
                        .opacity(reduceMotion ? 0.7 : 0.55 + 0.45 * wave)
                }
            }
            .frame(height: 12)
        }
        .accessibilityHidden(true)
    }
}

public struct ODTimedActivityLabel: View {
    public let title: String
    public let startedAt: Date
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.odWorkspaceVisible) private var workspaceVisible

    public init(title: String, startedAt: Date) {
        self.title = title
        self.startedAt = startedAt
    }

    public var body: some View {
        HStack(spacing: 10) {
            ODActivityDots()
            TimelineView(.animation(minimumInterval: 1, paused: !workspaceVisible || scenePhase != .active)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text("\(title) · \(seconds)s")
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(ODPalette.secondary)
                    .accessibilityIdentifier("chat.activity.timer")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

public struct ODContextCompactionBanner: View {
    public let message: String
    @ScaledMetric(relativeTo: .caption) private var iconWidth: CGFloat = 16

    public init(message: String) { self.message = message }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ODLayout.elementGap) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.caption.weight(.medium))
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(message)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(ODPalette.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ODPalette.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Context compacted", bundle: .module))
        .accessibilityValue(message)
        .accessibilityIdentifier("chat.contextCompaction")
    }
}
