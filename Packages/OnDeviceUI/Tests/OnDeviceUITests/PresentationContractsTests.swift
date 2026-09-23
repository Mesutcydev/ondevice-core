import Testing
import Foundation
@testable import OnDeviceUI

@MainActor
struct PresentationContractsTests {
    @Test func installedAndSelectedDoesNotMeanLoaded() throws {
        let store = ODStore(appearanceDefaults: nil)
        store.models = [ODModel(id: "a", name: "A", metadata: "", kind: .language, isInstalled: true)]
        store.selectedModelID = "a"
        store.modelPhase = .ready
        #expect(!store.isReady)
        #expect(!store.phase(for: store.models[0]).isReady)
        store.loadedModelID = "other"
        #expect(!store.isReady)
        store.loadedModelID = "a"
        #expect(store.isReady)
        store.modelPhase = .preparing(step: "Loading")
        #expect(!store.isReady)
        store.modelPhase = .failed(message: "No memory")
        #expect(!store.isReady)
    }

    @Test func composerHeightBudgetFollowsContentRows() {
        let empty = ODLayout.composerPanelHeight(textNaturalHeight: 44, footerNaturalHeight: 44)
        #expect(empty == 108)
        #expect((104...112).contains(empty))
        let attached = ODLayout.composerPanelHeight(textNaturalHeight: 44, footerNaturalHeight: 44, attachmentStripHeight: 44)
        #expect(attached == 156)
        #expect((152...160).contains(attached))
        #expect(ODLayout.composerModelFaceHeight == 32)
        #expect(ODLayout.composerModelFaceHeight < ODLayout.minimumHit)
        #expect(ODLayout.composerCorner == 26)
        #expect(ODLayout.composerInputStackGap == 8)
    }

    @Test func modelFaceSplitsOnlyAParameterToken() {
        let ornith = ODPresentation.modelFace(displayName: "Ornith 1.5 9B")
        #expect(ornith.title == "Ornith 1.5")
        #expect(ornith.size == "9B")
        #expect(ornith.accessibleName == "Ornith 1.5 9B")
        let hyphenated = ODPresentation.modelFace(displayName: "Qwen3-4B")
        #expect(hyphenated.title == "Qwen3")
        #expect(hyphenated.size == "4B")
        let dated = ODPresentation.modelFace(displayName: "Qwen3-4B 2507")
        #expect(dated.title == "Qwen3-4B 2507")
        #expect(dated.size == nil)
        let quantized = ODPresentation.modelFace(displayName: "Ornith 1.0 9B", metadata: "4-bit · ~5.6 GB")
        #expect(quantized.title == "Ornith 1.0")
        #expect(quantized.size == "9B")
        let fromMetadata = ODPresentation.modelFace(displayName: "Local model", metadata: "9B · Q5_K_M")
        #expect(fromMetadata.title == "Local model")
        #expect(fromMetadata.size == "9B")
        let plain = ODPresentation.modelFace(displayName: "Phi-3.5 Mini")
        #expect(plain.title == "Phi-3.5 Mini")
        #expect(plain.size == nil)
    }

    @Test func keyboardClearanceMatchesTheToolbarInsteadOfAConstant() {
        #expect(ODComposerKeyboardClearance.nextLift(current: 0, dockBottom: 800, buttonTop: 776) == 24)
        #expect(ODComposerKeyboardClearance.nextLift(current: 24, dockBottom: 776, buttonTop: 776) == 24)
        #expect(ODComposerKeyboardClearance.nextLift(current: 24, dockBottom: 770, buttonTop: 776) == 18)
        #expect(ODComposerKeyboardClearance.nextLift(current: 24, dockBottom: 800, buttonTop: 400) == nil)
    }

    @Test func submissionIsAnIntentUntilHostAcceptsIt() {
        let store = ODStore(appearanceDefaults: nil)
        let original = "  first line\nsecond line  "
        store.composerText = original
        store.draftAttachments = [.init(id: "file-1", name: "notes.txt", kind: .file)]
        var receivedText: String?
        var receivedIDs: [String] = []
        store.onAction = { action in
            if case let .sendMessageWithAttachments(text, attachmentIDs) = action {
                receivedText = text; receivedIDs = attachmentIDs
            }
        }
        store.send(.sendMessageWithAttachments(text: original, attachmentIDs: ["file-1"]))
        #expect(receivedText == original)
        #expect(receivedIDs == ["file-1"])
        #expect(store.composerText == original)
        #expect(store.draftAttachments.map(\.id) == ["file-1"])
        store.send(.removeAttachment("file-1"))
        #expect(store.draftAttachments.count == 1)
    }

    @Test func nextImageDraftDoesNotRelabelResult() {
        let store = ODStore(appearanceDefaults: nil)
        store.imageResultPrompt = "A lake"
        store.imageResultURL = URL(fileURLWithPath: "/tmp/fixture.png")
        store.imagePrompt = "A mountain"
        #expect(store.imageResultPrompt == "A lake")
        #expect(store.imageResultURL?.lastPathComponent == "fixture.png")
    }

    @Test func previewAndMinimizeDoNotSelectOrEndSession() {
        let store = ODStore(appearanceDefaults: nil)
        store.selectedVoiceID = "chosen"
        store.voicePreviewID = "preview"
        store.voiceSessionActive = true
        store.voiceSessionPresented = true
        store.voiceSessionPresented = false
        #expect(store.selectedVoiceID == "chosen")
        #expect(store.voiceSessionActive)
    }

    @Test func appearanceRestoresWithoutWritingHostDefaults() throws {
        let key = "ondevice-ui-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let store = ODStore(appearanceDefaults: defaults)
        #expect(store.appearance == .system)
        store.appearance = .dark
        #expect(ODStore(appearanceDefaults: defaults).appearance == .dark)
        store.appearance = .oled
        #expect(ODStore(appearanceDefaults: defaults).appearance == .oled)
        #expect(store.appearance.colorScheme == .dark)
        store.appearance = .system
        #expect(ODStore(appearanceDefaults: defaults).appearance == .system)
    }

    @Test func conversationSearchPreservesPinnedGroupsAndHostOrder() {
        let conversations: [ODRecentConversation] = [
            .init(id: "a", title: "Swift notes", subtitle: "Draft", dateLabel: "Today", isPinned: true),
            .init(id: "b", title: "A plan", subtitle: "SWIFT review", dateLabel: "Today"),
            .init(id: "c", title: "Reading", subtitle: "Book list", dateLabel: "Yesterday")
        ]
        let all = ODConversationGroups(conversations: conversations)
        #expect(all.pinned.map(\.id) == ["a"])
        #expect(all.recent.map(\.id) == ["b", "c"])
        let filtered = ODConversationGroups(conversations: conversations, query: "  swift  ")
        #expect(filtered.pinned.map(\.id) == ["a"])
        #expect(filtered.recent.map(\.id) == ["b"])
        #expect(ODConversationGroups(conversations: conversations, query: "absent").recent.isEmpty)
    }

}
