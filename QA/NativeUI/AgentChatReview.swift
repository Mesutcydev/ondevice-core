import SwiftUI
import OnDeviceUI

/// Illustrative data exercising production components; never performs inference or tools.
struct AgentChatReview: View {
    @EnvironmentObject private var store: ODStore
    @FocusState private var focused: Bool
    @State private var text = ""
    @State private var responding = !ProcessInfo.processInfo.arguments.contains("-agent-completed")
    @State private var startedAt = Date.now.addingTimeInterval(-36)
    @State private var completedSeconds = 36
    @State private var modelPresented = false
    @State private var replyPhase: ReplyPhase = ProcessInfo.processInfo.arguments.contains("-agent-waiting") ? .waiting : .reasoning

    private enum ReplyPhase { case waiting, reasoning, answer }

    private let results: [ChatMessage] = [
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!, role: .user,
                    content: "```tool_result\n{\"name\":\"file_read\",\"result\":\"Read portfolio-homepage.html\"}\n```"),
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!, role: .user,
                    content: "```tool_result\n{\"name\":\"calculator\",\"result\":\"Error: could not evaluate expression\"}\n```"),
        ChatMessage(id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!, role: .user,
                    content: "```tool_result\n{\"name\":\"file_read\",\"result\":\"Read iptv/index.html\"}\n```")
    ]

    private let memory: ConversationContextMemory? = {
        let dialog = (0..<24).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant,
                        content: "Project check \(index): " + String(repeating: "Keep the navigation and current project decisions. ", count: 12))
        }
        return ConversationContextCompactor.prepare(messages: dialog, existingMemory: nil,
            maxTokens: 2_048, modelDisplayName: "Qwen3 4B").memory
    }()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("UI fixture · no inference").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, ODLayout.pageInset)
                    HStack {
                        Spacer(minLength: 20)
                        Text("Audit the project’s pages and keep the current scrolling.")
                            .padding(12).background(ODPalette.input, in: RoundedRectangle(cornerRadius: 20))
                    }.padding(.horizontal, ODLayout.pageInset)
                    AssistantToolResultStrip(messages: results)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("The sitemap has several gaps I need to verify. Let me check a few remaining files before staging fixes.")
                            .font(.body).lineSpacing(4)
                        let content = replyPhase == .waiting ? "" : "<think>Checking the project structure and existing navigation before proposing a focused update." + (replyPhase == .answer || !responding ? "</think>" : "") + (replyPhase == .answer ? "The answer is streaming, with the existing reply bar still visible." : "")
                        let presentation = AssistantReplyPresentation(content: content, isStreaming: responding)
                        ODAssistantReplyLayout(reasoning: presentation.isReasoningOpen ? presentation.liveReasoningTail : presentation.reasoning,
                            showsReasoning: presentation.isWaiting || presentation.hasReasoning,
                            isReasoningOpen: presentation.isWaiting || presentation.isReasoningOpen,
                            seconds: responding && replyPhase != .answer ? nil : completedSeconds,
                            startedAt: startedAt) {
                            if responding && !presentation.answer.isEmpty {
                                ODStreamingText(content: presentation.answer)
                            }
                            if !responding {
                                Text("The checks are complete. The existing navigation and scrolling remain in place.")
                                    .accessibilityIdentifier("chat.fixture.completed")
                            }
                        }
                    }.padding(.horizontal, ODLayout.pageInset)
                }
                .padding(.top, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Project audit").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton { focused = false; store.conversationsPresented = true }
                        .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .principal) {
                    Button { focused = false; modelPresented = true } label: {
                        ODModelMenuLabel(displayName: "Qwen3 4B")
                    }.buttonStyle(.plain).accessibilityLabel("Choose chat model")
                        .accessibilityIdentifier("chat.modelPicker")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if responding && replyPhase != .answer {
                        Button("Next stage") {
                            if replyPhase == .waiting { replyPhase = .reasoning }
                            else {
                                completedSeconds = max(0, Int(Date.now.timeIntervalSince(startedAt)))
                                replyPhase = .answer
                            }
                        }.accessibilityIdentifier("chat.fixture.advance")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar(backgroundColor: ODPalette.background) {
                    VStack(spacing: 0) {
                        ODComposer(text: $text, focus: $focused, attachments: [], isResponding: responding,
                            canSend: !responding && !text.isEmpty, canStop: true, canAdd: !responding, canRemove: true,
                            notice: memory.map { AnyView(ODContextCompactionBanner(message: $0.compactionNotice)) },
                            onAdd: {}, onRemove: { _ in },
                            onSend: { _, _ in text = ""; startedAt = .now; responding = true },
                            onStop: {
                                completedSeconds = max(0, Int(Date.now.timeIntervalSince(startedAt)))
                                responding = false
                            })
                        if focused {
                            HStack { ODKeyboardDismissKey(focus: $focused); Spacer(minLength: 0) }
                                .padding(.horizontal, ODLayout.pageInset).frame(minHeight: ODLayout.minimumHit)
                        }
                    }
                }
            }
            .sheet(isPresented: $modelPresented) {
                NavigationStack {
                    Text("Qwen3 4B · UI fixture").navigationTitle("Models")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { modelPresented = false } } }
                }
            }
        }
    }
}
