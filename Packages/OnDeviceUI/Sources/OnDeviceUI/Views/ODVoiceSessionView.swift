import SwiftUI

@MainActor
public struct ODVoiceSessionView: View {
    private let accessories: AnyView?
    private let options: AnyView?
    private let routePicker: AnyView?
    private let activity: AnyView?
    private let onClose: (() -> Void)?
    public init(accessories: AnyView? = nil, options: AnyView? = nil, routePicker: AnyView? = nil, activity: AnyView? = nil, onClose: (() -> Void)? = nil) {
        self.options = options
        self.routePicker = routePicker
        self.activity = activity
        self.accessories = accessories
        self.onClose = onClose
    }
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var sessionMetadata: String {
        [store.selectedModel.map { ODPresentation.modelName($0.name, compact: true).components(separatedBy: " · ").first ?? $0.name }, store.executionLabel]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var statusTitle: String {
        if store.voicePhase == .listening && !store.microphoneEnabled {
            return "Microphone muted"
        }
        return store.voicePhase.title
    }

    private var statusSubtitle: String {
        if store.voicePhase == .listening && !store.microphoneEnabled {
            return "Turn on the microphone when you’re ready."
        }
        return store.voicePhase.subtitle
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    // One continuous composition: identity, live state and
                    // transcript flow with steady spacing instead of
                    // spring-loaded gaps that disconnect them.
                    VStack(spacing: ODLayout.groupGap) {
                        identity
                        sessionActivity
                        if let accessories { accessories }

                        if !store.voiceTranscript.isEmpty {
                            transcript.padding(.top, ODLayout.elementGap)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, ODLayout.gutter)
                }
                .scrollBounceBehavior(.basedOnSize)

                sessionControls
                    .padding(.horizontal, ODLayout.gutter)
                    .padding(.vertical, ODLayout.pageInset)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Voice conversation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let options { ToolbarItem(placement: .topBarTrailing) { options } }
                if store.voiceSessionActive && store.capabilities.canMinimizeVoiceSession {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Minimize voice conversation", systemImage: "chevron.down") {
                            store.voiceSessionPresented = false
                onClose?()
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityHint("The conversation stays active. Return from Voice in the app menu.")
                    }
                } else if !store.voiceSessionActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close voice conversation", systemImage: "xmark") {
                            store.voiceSessionPresented = false
                onClose?()
                        }
                        .labelStyle(.iconOnly)
                    }
                }
            }
        }
        .tint(ODPalette.text)
        .interactiveDismissDisabled(store.voiceSessionActive)
        .onChange(of: store.voiceSessionActive) { wasActive, isActive in
            // The host ends capture/playback first, then publishes inactive.
            // Minimize changes presentation only and never reaches this branch.
            if wasActive && !isActive && store.voicePhase == .idle {
                store.voiceSessionPresented = false
                onClose?()
            }
        }
    }

    private var identity: some View {
        VStack(spacing: ODLayout.elementGap) {
            Text(store.selectedVoice?.name ?? "Voice")
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(ODPalette.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !sessionMetadata.isEmpty {
                Text(sessionMetadata)
                    .font(.footnote)
                    .foregroundStyle(ODPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                audioRoute
                if let routePicker { routePicker }
            }.padding(.top, ODLayout.unit)
            if let notice = store.voiceSessionNotice, !notice.isEmpty {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(ODPalette.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ODLayout.unit)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, ODLayout.groupGap)
    }

    @ViewBuilder
    private var audioRoute: some View {
        if store.capabilities.canSelectAudioRoute {
            Button {
                store.send(.selectAudioRoute)
            } label: {
                Label("Output: \(store.audioRouteName)", systemImage: "speaker.wave.2")
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .frame(minHeight: ODLayout.minimumHit)
            .disabled(!store.canPerformActions)
            .accessibilityLabel("Audio output, \(store.audioRouteName)")
            .accessibilityHint("Change where conversation audio plays")
        } else {
            Label("Output: \(store.audioRouteName)", systemImage: "speaker.wave.2")
                .font(.subheadline)
                .foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: ODLayout.minimumHit)
                .accessibilityLabel("Audio output, \(store.audioRouteName)")
        }
    }

    private var sessionActivity: some View {
        VStack(spacing: 4 * ODLayout.unit) {
            Group {
                if let activity { activity }
                else { ODVoiceActivityMark(isActive: store.voicePhase.isActive && store.voiceSessionActive) }
            }.frame(height: 13 * ODLayout.unit)
            VStack(spacing: ODLayout.elementGap) {
                Text(statusTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(ODPalette.text)
                Text(statusSubtitle)
                    .font(.body)
                    .foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, ODLayout.labelGap)
    }

    /// Only host-supplied session messages appear here. No example transcript
    /// or inferred recording state is generated by this presentation layer.
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 5 * ODLayout.unit) {
            Text("Conversation")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ODPalette.secondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(store.voiceTranscript) { message in
                VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                    Text(message.role == .user ? "You" : "OnDevice")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ODPalette.secondary)
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(ODPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(message.role == .user ? ODLayout.labelGap : 0)
                .background(message.role == .user ? ODPalette.chrome : Color.clear,
                            in: RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, ODLayout.pageInset)
    }

    private var sessionControls: some View {
        HStack(alignment: .top, spacing: 4 * ODLayout.unit) {
            ODVoiceCircleControl(
                symbol: store.speakerEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                title: store.speakerEnabled ? "Audio on" : "Audio muted",
                actionLabel: store.speakerEnabled ? "Mute playback" : "Unmute playback",
                stateValue: store.speakerEnabled ? "On" : "Off"
            ) {
                store.send(.setSpeakerEnabled(!store.speakerEnabled))
            }
            .disabled(!store.canPerformActions || !store.voiceSessionActive || !store.capabilities.canControlSpeaker)

            ODVoiceCircleControl(
                symbol: store.microphoneEnabled ? "mic.fill" : "mic.slash.fill",
                title: store.microphoneEnabled ? "Mic on" : "Mic off",
                actionLabel: store.microphoneEnabled ? "Mute microphone" : "Unmute microphone",
                stateValue: store.microphoneEnabled ? "On" : "Off",
                prominent: store.microphoneEnabled
            ) {
                store.send(.setMicrophoneEnabled(!store.microphoneEnabled))
            }
            .disabled(!store.canPerformActions || !store.voiceSessionActive || !store.capabilities.canControlMicrophone)

            ODVoiceCircleControl(
                symbol: store.voiceSessionActive ? "phone.down.fill" : "checkmark",
                title: store.voiceSessionActive ? "End" : "Done",
                actionLabel: store.voiceSessionActive ? "End voice conversation" : "Close voice conversation",
                stateValue: "",
                prominent: store.voiceSessionActive,
                destructive: store.voiceSessionActive,
                hint: store.voiceSessionActive ? "Stops microphone capture and conversation audio" : ""
            ) {
                if store.voiceSessionActive {
                    store.send(.endVoiceSession)
                } else {
                    store.voiceSessionPresented = false
                onClose?()
                }
            }
            .disabled(store.voiceSessionActive && !store.canPerformActions)
        }
    }
}

/// A static phase symbol, never a fabricated audio-level meter.
private struct ODVoiceActivityMark: View {
    let isActive: Bool
    var body: some View {
        Image(systemName: "waveform")
            .font(.largeTitle).imageScale(.large)
            .foregroundStyle(isActive ? ODPalette.text : ODPalette.secondary)
            .accessibilityHidden(true)
    }
}

/// The system draws each circle and its material. Labels remain separate from
/// the button surface so each control keeps its native circular interaction.
private struct ODVoiceCircleControl: View {
    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 6 * ODLayout.unit
    let symbol: String
    let title: String
    let actionLabel: String
    let stateValue: String
    var prominent = false
    var destructive = false
    var hint = ""
    let action: () -> Void

    init(symbol: String, title: String, actionLabel: String, stateValue: String,
         prominent: Bool = false, destructive: Bool = false, hint: String = "",
         action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.actionLabel = actionLabel
        self.stateValue = stateValue
        self.prominent = prominent
        self.destructive = destructive
        self.hint = hint
        self.action = action
    }

    var body: some View {
        VStack(spacing: ODLayout.labelGap) {
            styledButton
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .frame(minWidth: 16 * ODLayout.unit, minHeight: 16 * ODLayout.unit)
                .accessibilityLabel(actionLabel)
                .accessibilityValue(stateValue)
                .accessibilityHint(hint)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(ODPalette.text)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 22 * ODLayout.unit)
    }

    @ViewBuilder
    private var styledButton: some View {
        if prominent {
            button
                .buttonStyle(.glassProminent)
                // The brand's dark red is a pastel intended for text. Use
                // native red for a filled End control and its system label.
                .tint(destructive ? .red : .blue)
        } else {
            button
                .buttonStyle(.glass)
                .tint(ODPalette.text)
        }
    }

    private var button: some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .medium))
                .frame(width: iconSize + ODLayout.elementGap, height: iconSize + ODLayout.elementGap)
        }
    }
}
