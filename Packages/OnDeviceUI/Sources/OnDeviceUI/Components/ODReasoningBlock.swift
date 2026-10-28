import SwiftUI

/// Keeps the transcript's live reasoning tail and ruled disclosure while adding elapsed time.
public struct ODReasoningBlock: View {
    public let content: String
    public let isOpen: Bool
    public let seconds: Int?
    public let startedAt: Date?
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(content: String, isOpen: Bool, seconds: Int? = nil, startedAt: Date? = nil) {
        self.content = content
        self.isOpen = isOpen
        self.seconds = seconds
        self.startedAt = startedAt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    if isOpen {
                        if let startedAt {
                            ODTimedActivityLabel(title: "Reasoning…", startedAt: startedAt)
                        } else {
                            HStack(spacing: 10) {
                                ODActivityDots()
                                Text("Reasoning…", bundle: .module)
                                    .font(.footnote).foregroundStyle(ODPalette.secondary)
                            }
                        }
                    } else {
                        Group {
                            if let seconds { Text("Thought for \(seconds)s", bundle: .module) }
                            else { Text("Thought", bundle: .module) }
                        }
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(ODPalette.secondary)
                    }
                    if isOpen && !expanded {
                        ODStreamingText(content: "", font: .footnote, color: ODPalette.secondary)
                            .fixedSize()
                    }
                    Rectangle().fill(ODPalette.line).frame(height: 1).accessibilityHidden(true)
                    Text(expanded ? "Hide" : "Show", bundle: .module)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(ODPalette.secondary)
                }
                .padding(.vertical, 4)
                .frame(minHeight: ODLayout.minimumHit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(Text(odKey: expanded ? "Expanded" : "Collapsed"))
            .accessibilityIdentifier("chat.reasoning")

            if expanded && isOpen {
                ODStreamingText(content: content, font: .system(size: 14),
                                color: ODPalette.secondary, lineSpacing: 5)
                    .padding(.top, content.isEmpty ? 4 : 6)
                    .padding(.bottom, 8)
            } else if expanded {
                Rectangle().fill(ODPalette.line).frame(height: 1)
                    .padding(.vertical, 6).accessibilityHidden(true)
                reasoningText.textSelection(.enabled)
            }
        }
    }

    private var reasoningText: some View {
        Text(content)
            .font(.system(size: 14))
            .foregroundStyle(ODPalette.secondary)
            .lineSpacing(5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
