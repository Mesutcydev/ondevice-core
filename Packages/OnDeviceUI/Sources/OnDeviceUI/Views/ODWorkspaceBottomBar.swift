import SwiftUI

private struct ODWorkspaceVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var odWorkspaceVisible: Bool {
        get { self[ODWorkspaceVisibleKey.self] }
        set { self[ODWorkspaceVisibleKey.self] = newValue }
    }
}

/// One bottom-space owner per workspace. The session always precedes that page's
/// composer/action, so keyboard and scroll insets account for the combined height.
public struct ODWorkspaceBottomBar<Content: View>: View {
    @EnvironmentObject private var store: ODStore
    private let content: Content
    public init(@ViewBuilder content: () -> Content) { self.content = content() }
    public var body: some View {
        VStack(spacing: 0) {
            ODVoiceSessionAccessory()
            content
        }
        .background { ODPageBackground() }
    }
}

public struct ODVoiceSessionAccessory: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    public init() {}
    private var micState: String { !store.microphoneEnabled ? "Mic off" : store.microphoneCapturing ? "Mic on" : "Mic paused" }
    public var body: some View {
        if workspaceVisible && store.voiceSessionActive && !store.voiceSessionPresented {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                Button {
                    store.returnToVoiceSession()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(store.selectedVoice?.name ?? "Voice") · \(store.voicePhase.title)")
                                .font(.subheadline.weight(.semibold))
                            Text("\(micState) · \(store.speakerEnabled ? "Audio on" : "Audio muted")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to voice conversation")
                .accessibilityValue("\(store.selectedVoice?.name ?? "Voice"), \(store.voicePhase.title), \(micState), \(store.speakerEnabled ? "Audio on" : "Audio muted")")
                .accessibilityIdentifier("session.return")
                Button("End", role: .destructive) { store.send(.endVoiceSession) }
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityLabel("End voice conversation")
                    .accessibilityIdentifier("session.end")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(reduceTransparency ? AnyShapeStyle(ODPalette.surface) : AnyShapeStyle(.regularMaterial), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, ODLayout.pageInset).padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("session.accessory")
        }
    }
}
