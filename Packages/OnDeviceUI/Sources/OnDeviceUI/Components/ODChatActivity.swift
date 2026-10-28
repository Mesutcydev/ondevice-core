import SwiftUI
import UIKit

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

private extension ODToolEvent.Status {
    var label: LocalizedStringResource {
        switch self {
        case .running: ODLocalizedString("Running")
        case .success: ODLocalizedString("Completed")
        case .failure: ODLocalizedString("Failed")
        case .cancelled: ODLocalizedString("Cancelled")
        }
    }
}

/// Replayed updates replace an attempt's state without increasing its count.
public struct ODToolActivitySummary: Equatable {
    public let events: [ODToolEvent]
    public var completedCount: Int { events.filter { $0.status != .running }.count }
    public var runningCount: Int { events.filter { $0.status == .running }.count }
    public var failureCount: Int { events.filter { $0.status == .failure }.count }

    public init(events: [ODToolEvent]) {
        var indices: [UUID: Int] = [:]
        var unique: [ODToolEvent] = []
        for event in events {
            if let index = indices[event.id] { unique[index] = event }
            else { indices[event.id] = unique.count; unique.append(event) }
        }
        self.events = unique
    }
}

/// Retains the existing compact pills and adds an optional full-width activity log.
/// The host owns disclosure state so recycling a row cannot reset the choice.
public struct ODToolActivityGroup: View {
    public let events: [ODToolEvent]
    @Binding public var isExpanded: Bool
    @State private var selectedEvent: ODToolEvent?
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(events: [ODToolEvent], isExpanded: Binding<Bool>) {
        self.events = events
        _isExpanded = isExpanded
    }

    public var body: some View {
        let summary = ODToolActivitySummary(events: events)
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Button { isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: ODLayout.elementGap) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold)).accessibilityHidden(true)
                    let summaryLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: ODLayout.unit))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: ODLayout.elementGap))
                    summaryLayout {
                        if summary.runningCount > 0 {
                            Text("Using tools · \(summary.completedCount) complete · \(summary.runningCount) running", bundle: .module)
                        } else if summary.completedCount == 1 {
                            Text("Used 1 tool", bundle: .module)
                        } else {
                            Text("Used \(summary.completedCount) tools", bundle: .module)
                        }
                        if summary.failureCount > 0 {
                            Label { Text("\(summary.failureCount) failed", bundle: .module) } icon: {
                                Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .font(.footnote)
                .foregroundStyle(ODPalette.text)
                .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(isExpanded ? ODLocalizedString("Expanded") : ODLocalizedString("Collapsed")))
            .accessibilityIdentifier("chat.tools.summary")

            if isExpanded {
                LazyVStack(spacing: 0) {
                    ForEach(summary.events) { event in
                        Button { selectedEvent = event } label: {
                            HStack(alignment: .firstTextBaseline, spacing: ODLayout.elementGap) {
                                ODToolStatusIcon(status: event.status)
                                Text(event.title).foregroundStyle(ODPalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Text(event.status.label).font(.caption2).foregroundStyle(ODPalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(.footnote, design: .monospaced))
                            .padding(ODLayout.elementGap)
                            .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(Text("Shows tool details", bundle: .module))
                        .accessibilityIdentifier("chat.tool.\(event.id.uuidString)")
                    }
                }
                .background(ODPalette.input, in: RoundedRectangle(cornerRadius: 12))
            } else {
                ODToolPillStrip(events: summary.events)
            }
        }
        .sheet(item: $selectedEvent) { event in
            ODToolDetailView(event: event)
        }
    }
}

private struct ODToolStatusIcon: View {
    let status: ODToolEvent.Status
    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini).accessibilityHidden(true)
        case .success: Image(systemName: "checkmark.circle").foregroundStyle(ODPalette.secondary).accessibilityHidden(true)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).accessibilityHidden(true)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(ODPalette.secondary).accessibilityHidden(true)
        }
    }
}

private struct ODToolDetailView: View {
    let event: ODToolEvent
    @Environment(\.dismiss) private var dismiss
    @State private var visibleCharacters = 8_192
    @State private var copied = false
    private var output: String { event.detail.isEmpty ? event.title : event.detail }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                    Text(event.title).font(.headline).textSelection(.enabled)
                    Label { Text(event.status.label) } icon: { ODToolStatusIcon(status: event.status) }
                        .font(.footnote).foregroundStyle(ODPalette.secondary)
                    Text(String(output.prefix(visibleCharacters)))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("chat.tool.details")
                    if output.count > visibleCharacters {
                        Button { visibleCharacters += 8_192 } label: { Text("Show more output", bundle: .module) }
                            .frame(minHeight: ODLayout.minimumHit)
                            .accessibilityIdentifier("chat.tool.more")
                    }
                }
                .padding()
            }
            .navigationTitle(Text("Tool details", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        UIPasteboard.general.string = output
                        copied = true
                    } label: {
                        Text(copied ? ODLocalizedString("Copied") : ODLocalizedString("Copy"))
                    }
                    .accessibilityIdentifier("chat.tool.copy")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: { Text("Done", bundle: .module) }
                }
            }
        }
        .tint(ODPalette.text)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
                    .accessibilityValue(Text(event.status.label))
                    .accessibilityHint(Text("Shows tool details", bundle: .module))
                    .accessibilityIdentifier("chat.tool.\(event.id.uuidString)")
                }
            }
        }
        .frame(minHeight: ODLayout.minimumHit)
        .accessibilityIdentifier("chat.tools")
        .sheet(item: $selectedEvent) { event in
            ODToolDetailView(event: event)
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

/// The model-activity indicator: tokens streaming along the brand mark.
/// Only this small view redraws; transcript text is not re-laid out.
public struct ODActivityDots: View {
    public init() {}

    public var body: some View {
        ODBrandMark(height: 10, motion: .live)
            .foregroundStyle(ODPalette.text)
            .frame(height: 12)
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
                Text("\(Text(odKey: title)) · \(seconds)s", bundle: .module)
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
