import SwiftUI
import UIKit

/// A native conversation workspace. The host accepts and streams messages.
@MainActor
struct ODChatView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var composerFocused: Bool
    @State private var followsLatestMessage = true
    @State private var detailModel: ODModel?
    @State private var deferredModelAction: ODAction?

    private var phase: ODModelPhase {
        guard let model = store.selectedModel else { return .unloaded }
        return store.phase(for: model)
    }
    private var hasDraft: Bool {
        !store.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.draftAttachments.isEmpty
    }
    private var canSend: Bool {
        store.isReady && store.capabilities.canSendMessages && store.canPerformActions
        && !store.isResponding && hasDraft
        && (store.draftAttachments.isEmpty || store.capabilities.canSendAttachments)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        if store.messages.isEmpty {
                            emptyWorkspace
                                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - ODLayout.pageInset * 2))
                                .padding(.horizontal, ODLayout.pageInset)
                                .padding(.vertical, ODLayout.pageInset)
                        } else {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 14) {
                                    ForEach(store.messages) { message in
                                        ODTranscriptMessage(message: message,
                                                            availableWidth: ODLayout.contentWidth(availableWidth: geometry.size.width))
                                            .id(message.id)
                                    }
                                    if store.isResponding {
                                        HStack(spacing: ODLayout.elementGap) {
                                            ProgressView().accessibilityHidden(true)
                                            Text("Responding").font(.footnote).foregroundStyle(.secondary)
                                        }
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .padding(.horizontal, ODLayout.pageInset)
                                .padding(.top, ODLayout.pageInset)
                                Color.clear
                                    .frame(height: ODLayout.chatThreadBottomClearance)
                                    .id("conversation-bottom")
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(DragGesture(minimumDistance: ODLayout.labelGap).onChanged { _ in
                        followsLatestMessage = false
                    })
                    .overlay(alignment: .bottomTrailing) {
                        if !followsLatestMessage && !store.messages.isEmpty {
                            Button {
                                followsLatestMessage = true
                                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            } label: {
                                Label("Latest", systemImage: "arrow.down")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .controlSize(.large)
                            .accessibilityLabel("Return to the latest message")
                            .padding(ODLayout.labelGap)
                        }
                    }
                    .onChange(of: store.selectedConversationID) { _, _ in
                        followsLatestMessage = true
                        if !store.messages.isEmpty { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.messages.last?.text) { _, _ in
                        guard followsLatestMessage else { return }
                        proxy.scrollTo("conversation-bottom", anchor: .bottom)
                    }
                    .onChange(of: store.messages.last?.id, initial: true) { _, _ in
                        guard followsLatestMessage, !store.messages.isEmpty else { return }
                        if reduceMotion {
                            proxy.scrollTo("conversation-bottom", anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.18)) {
                                proxy.scrollTo("conversation-bottom", anchor: .bottom)
                            }
                        }
                    }
                }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar {
                    VStack(spacing: 0) {
                        composer
                        if composerFocused {
                            HStack {
                                ODKeyboardDismissKey(focus: $composerFocused)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, ODLayout.pageInset)
                            .frame(minHeight: ODLayout.minimumHit)
                        }
                    }
                }
            }
            .navigationTitle(store.selectedConversation?.title ?? "OnDevice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton {
                        composerFocused = false
                        store.conversationsPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Open conversations and app menu")
                    .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .principal) {
                    modelSelector
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New conversation", systemImage: "square.and.pencil") {
                        followsLatestMessage = true
                        store.send(.newConversation)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(!store.canPerformActions || store.isResponding)
                }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .chat { composerFocused = false }
            }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { composerFocused = false }
            }
            .sheet(item: $detailModel, onDismiss: {
                if let action = deferredModelAction {
                    deferredModelAction = nil
                    store.send(action)
                }
            }) { model in
                ODModelDetailView(modelID: model.id) { action in
                    deferredModelAction = action
                    detailModel = nil
                }.environmentObject(store)
            }
        }
    }

    private var emptyHelper: String {
        let names = store.draftAttachments.map(\.name).filter { !$0.isEmpty }
        if names.count > 1 { return "Ask about the attached files." }
        if let name = names.first { return "Ask about \(name)." }
        return "Write a message, or attach a file."
    }

    private var emptyWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New chat").font(.title2.weight(.medium))
            Text(emptyHelper)
                .font(.body).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var composer: some View {
        ODComposer(
            text: $store.composerText, focus: $composerFocused,
            attachments: store.draftAttachments, isResponding: store.isResponding,
            canSend: canSend, canStop: store.canPerformActions && store.capabilities.canStopGeneration,
            canAdd: store.canPerformActions && store.capabilities.canAddAttachments && !store.isResponding,
            canRemove: store.canPerformActions && store.capabilities.canRemoveAttachments && !store.isResponding,
            microphone: nil,
            notice: AnyView(VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                stateNotice
                if let reason = draftAvailabilityReason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                }
            }),
            onVoice: {
                composerFocused = false
                if store.voiceSessionActive { store.voiceSessionPresented = true }
                else {
                    store.selectedTab = .voice
                    if store.capabilities.canStartVoice { store.send(.beginVoiceSession) }
                }
            },
            thinking: store.thinkingEnabled,
            onThinking: { store.send(.setThinking($0)) },
            onAdd: { store.send(.addAttachment) },
            onRemove: { store.send(.removeAttachment($0)) },
            onSend: { text, ids in
                followsLatestMessage = true
                if ids.isEmpty { store.send(.sendMessage(text)) }
                else { store.send(.sendMessageWithAttachments(text: text, attachmentIDs: ids)) }
            },
            onStop: { store.send(.stopGeneration) }
        )
    }

    /// Explain an unavailable Send only after the user has written a draft.
    /// Idle chat keeps no status strip; an unavailable action gets context after a draft exists.
    private var draftAvailabilityReason: String? {
        guard hasDraft, !store.isResponding else { return nil }
        guard let model = store.selectedModel else { return "Model required" }
        guard model.kind == .language else { return "Assistant model required" }
        guard model.isInstalled else { return "Model not installed" }
        if !store.isReady {
            if phase.isPreparing { return nil }
            if case .failed = phase { return nil }
            return "Load the model to send"
        }
        if !store.canPerformActions || !store.capabilities.canSendMessages {
            return "Messaging unavailable"
        }
        if !store.draftAttachments.isEmpty && !store.capabilities.canSendAttachments {
            return "Attachment sending unavailable"
        }
        return nil
    }

    private var modelSelector: some View {
        Menu {
            Button("Choose an assistant model", systemImage: "cube") {
                composerFocused = false
                store.selectedTab = .models
            }
            if let model = store.selectedModel {
                Button("Model details", systemImage: "info.circle") { detailModel = model }
                if !store.isReady && !phase.isPreparing && model.isInstalled && model.kind == .language {
                    Button("Load \(model.name)", systemImage: "arrow.up.circle") { store.send(.loadModel(model.id)) }
                        .disabled(!store.canPerformActions || !store.capabilities.canLoadModels || store.isResponding)
                }
            }
            if !store.personas.isEmpty {
                Picker(selection: Binding(
                    get: { store.selectedPersonaID ?? "" },
                    set: { store.send(.selectPersona($0)) }
                )) {
                    ForEach(store.personas) { persona in
                        Label(persona.name, systemImage: persona.symbol).tag(persona.id)
                    }
                } label: {
                    Label("Persona", systemImage: "person.crop.circle")
                }
                .pickerStyle(.menu)
                .disabled(!store.canPerformActions)
                .accessibilityIdentifier("chat.personaPicker")
            }
            Button("Device status", systemImage: "iphone") {
                composerFocused = false
                store.secondaryRoute = .device
            }
        } label: {
            ODModelMenuLabel(displayName: store.selectedModel?.name ?? "",
                             metadata: store.selectedModel?.metadata)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(store.selectedModel?.name ?? "None selected")
        .accessibilityHint("Choose or load an assistant model, pick a persona, or inspect details")
        .accessibilityIdentifier("chat.modelPicker")
    }

    @ViewBuilder private var stateNotice: some View {
        switch phase {
        case .preparing(let step):
            HStack(alignment: .top, spacing: ODLayout.elementGap) {
                ProgressView().accessibilityHidden(true)
                Text(step.isEmpty ? "Preparing \(store.selectedModel?.name ?? "model")…" : step)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        case .failed(let message):
            VStack(alignment: .leading, spacing: ODLayout.unit) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                if let model = store.selectedModel, model.isInstalled {
                    Button("Try loading again") { store.send(.loadModel(model.id)) }
                        .font(.footnote).frame(minHeight: ODLayout.minimumHit)
                        .disabled(!store.canPerformActions || !store.capabilities.canLoadModels || store.isResponding)
                }
            }
        case .unloaded, .ready:
            EmptyView()
        }
    }

    private func sendMessage() {
        guard canSend else { return }
        followsLatestMessage = true
        let text = store.composerText
        let attachmentIDs = store.draftAttachments.map(\.id)
        if attachmentIDs.isEmpty {
            store.send(.sendMessage(text))
        } else {
            store.send(.sendMessageWithAttachments(text: text, attachmentIDs: attachmentIDs))
        }
        // Preserve the exact draft, including code indentation. Both values above are
        // immutable snapshots. The host resolves IDs and clears
        // the draft and attachment metadata only after accepting this submission.
    }
}

private struct ODTranscriptMessage: View {
    @Environment(\.displayScale) private var displayScale
    let message: ODMessage
    let availableWidth: CGFloat

    var body: some View {
        Group {
            if message.role == .user {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    Text(message.text)
                        .font(.body)
                        .foregroundStyle(ODPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.horizontal, ODLayout.bubbleInsetH)
                        .padding(.vertical, ODLayout.bubbleInsetV)
                        .background(ODPalette.input, in: RoundedRectangle(cornerRadius: ODLayout.bubbleCorner))
                        .frame(maxWidth: ODLayout.maxUserBubbleWidth(contentWidth: availableWidth, displayScale: displayScale), alignment: .trailing)
                        .accessibilityIdentifier("chat.message.user.\(message.id.uuidString)")
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(message.text.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .lineSpacing(ODLayout.unit)
                            .foregroundStyle(ODPalette.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = message.text }
        }
        .accessibilityLabel(message.role == .user ? "You: \(message.text)" : "OnDevice: \(message.text)")
    }
}
