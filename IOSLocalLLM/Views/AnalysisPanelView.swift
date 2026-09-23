import SwiftUI
import OnDeviceUI

/// Native presentation over the existing capture, review, Q&A and sharing pipelines.
struct AnalysisPanelView: View {
    let staticResult: AnalysisResult
    @ObservedObject var analysis: AnalysisService
    @Binding var isPresented: Bool
    @State private var selectedTab = 0
    @State private var showCodeEditor = false
    @State private var editableCode: String = ""
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var pendingQuestion: String = ""
    @FocusState private var questionFocused: Bool
    /// Presents OnboardingModelPickerView when a result's suggested
    /// action is .pickVisualModel — keeps the recovery flow inline
    /// rather than dumping the user on the Models tab.
    @State private var showModelPickerSheet: Bool = false
    private let bridge = AppBridge.shared
    private let settings = AppSettings.shared

    @Environment(\.koduTheme) private var T

    init(result: AnalysisResult, analysis: AnalysisService, isPresented: Binding<Bool>) {
        self.staticResult = result
        self.analysis = analysis
        self._isPresented = isPresented
    }

    /// Always reflect the latest stored copy of the result (for live Q&A streaming).
    private var result: AnalysisResult {
        analysis.analysisResults.first(where: { $0.id == staticResult.id })
            ?? analysis.activeResult
            ?? staticResult
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                headerView
                if result.mode == .visual {
                    visualDescriptionTab
                } else {
                    Picker("Result", selection: $selectedTab) {
                        Text("Code").tag(0)
                        Text("Review").tag(1)
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 20)
                    if selectedTab == 0 { codeTab } else { reviewWithQATab }
                }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Capture result").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { isPresented = false } }
                if analysis.isAnalyzing && analysis.activeResult?.id == result.id {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Stop", systemImage: "stop.fill") { analysis.cancelCurrentAnalysis() }
                            .accessibilityLabel("Stop image analysis")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ODKeyboardDismissKey(focus: $questionFocused)
                    Spacer(minLength: 0)
                }
            }
        }
        .onAppear {
            editableCode = result.extractedCode
            // Auto-read if enabled
            if settings.voiceAutoRead {
                let textToRead: String = {
                    if result.mode == .visual { return result.extractedCode }
                    return [result.reviewMarkdown, result.extractedCode].filter { !$0.isEmpty }.first ?? ""
                }()
                if !textToRead.isEmpty {
                    VoiceService.shared.speak(textToRead)
                }
            }
        }
        .onDisappear { VoiceService.shared.stop() }
        .sheet(isPresented: $showCodeEditor) {
            CodePanelView(code: $editableCode, language: detectLanguage(result.extractedCode))
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        // Visual-model picker invoked from the inline action button
        // under a "FastVLM not available" fallback banner.
        .sheet(isPresented: $showModelPickerSheet) {
            NavigationStack {
                OnboardingModelPickerView {
                    showModelPickerSheet = false
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showModelPickerSheet = false }
                            .font(T.conversationBody)
                            .foregroundColor(T.ink2)
                    }
                }

            }
            .preferredColorScheme(settings.resolvedColorScheme)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(result.detection.label).font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if result.isStreaming { ProgressView().accessibilityLabel("Analyzing") }
                Text(result.timestamp, style: .time).font(.footnote).foregroundStyle(.secondary)
            }
            if let reason = result.fallbackReason {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
                if let action = result.suggestedAction { suggestedActionButton(action) }
            }
            if !result.extractedCode.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { resultActions }
                    VStack(alignment: .leading, spacing: 12) { resultActions }
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8)
    }

    @ViewBuilder private var resultActions: some View {
        Button("Ask in Chat", systemImage: "bubble.left") {
            bridge.sendToAssistant(code: result.extractedCode,
                source: result.ocrFallback ? "Camera OCR" : "Lens",
                image: result.ciImage.map { UIImage(ciImage: $0) } ?? result.thumbnail)
            isPresented = false
        }.buttonStyle(.glass)
        Menu("Result actions", systemImage: "ellipsis") {
            Button("Share", systemImage: "square.and.arrow.up") {
                shareItems = [result.fullMarkdown]; showShareSheet = true
            }
            Button("Copy text", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = result.extractedCode
            }
            if result.mode != .visual {
                Button("Edit code", systemImage: "square.and.pencil") { showCodeEditor = true }
            }
        }.buttonStyle(.glass)
        VoiceControlsView(text: result.mode == .visual || selectedTab == 0 ? result.extractedCode : result.reviewMarkdown)
    }

    // MARK: - Visual description tab

    private var visualDescriptionTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        // Tappable area to dismiss keyboard
                        Color.clear.frame(height: 0)
                        if result.extractedCode.isEmpty && result.isStreaming {
                            HStack(spacing: 6) {
                                StreamingCaret()
                                KMono(text: "describing scene…", size: 11, color: T.ink3)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                        } else if result.extractedCode.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "eye.slash")
                                    .font(.system(size: 28))
                                    .foregroundColor(T.ink3)
                                Text(result.fallbackReason ?? "FastVLM pipeline required for Visual mode.")
                                    .font(T.sans(12))
                                    .foregroundColor(T.ink3)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else {
                            // Scene description (with caret while streaming)
                            VStack(alignment: .leading, spacing: 0) {
                                // Selection toggled by streaming state to keep
                                // CoreText's Futhark line-break allocator from
                                // overflowing on long, rapidly-updating output.
                                // See StreamSafeTextSelection in ContentView.swift.
                                Text(result.extractedCode)
                                    .font(T.conversationBody)
                                    .foregroundColor(T.ink)
                                    .lineSpacing(4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .modifier(StreamSafeTextSelection(streaming: result.isStreaming))
                                if result.isStreaming {
                                    StreamingCaret().padding(.top, 4)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .kGlass(cornerRadius: StudioRadius.tile, fallbackFill: T.surface)

                            // Q&A exchanges
                            ForEach(result.questionAnswers) { qa in
                                qaBubble(qa).id(qa.id)
                            }
                        }
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    TapGesture().onEnded { questionFocused = false }
                )
                .onChange(of: result.questionAnswers.last?.answer) { _, _ in
                    if let last = result.questionAnswers.last {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            askQuestionBar
        }
    }

    // MARK: - Q&A bubble

    private func qaBubble(_ qa: AnalysisResult.QAExchange) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Spacer(minLength: 24)
                Text(qa.question).font(.body).padding(.horizontal, 16).padding(.vertical, 12)
                    .background(ODPalette.input, in: RoundedRectangle(cornerRadius: 20))
            }
            Text(qa.answer.isEmpty && qa.isStreaming ? "Thinking…" : qa.answer)
                .font(.body).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(StreamSafeTextSelection(streaming: qa.isStreaming))
        }
    }

    private var askQuestionBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Ask about this image", text: $pendingQuestion, axis: .vertical)
                .font(.body).lineLimit(1...6).focused($questionFocused).submitLabel(.return)
                .padding(12).background(ODPalette.surface, in: RoundedRectangle(cornerRadius: 20))
            Button("Send question", systemImage: "arrow.up", action: submitQuestion)
                .labelStyle(.iconOnly).buttonStyle(.glassProminent).buttonBorderShape(.circle)
                .controlSize(.large).tint(ODPalette.send).foregroundStyle(ODPalette.onSend)
                .disabled(!canSendQuestion || result.isStreaming)
        }
        .padding(20)
    }

    private var canSendQuestion: Bool {
        !pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitQuestion() {
        let q = pendingQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        pendingQuestion = ""
        questionFocused = false
        KeyboardDismiss.now()
        HapticManager.messageSent()
        analysis.askQuestion(q, about: result)
    }

    private var codeTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if result.extractedCode.isEmpty && result.isStreaming {
                    // Streaming placeholder
                    HStack(spacing: 6) {
                        StreamingCaret()
                        KMono(text: "waiting for first token…", size: 11, color: T.ink3)
                    }
                    .padding()
                } else if result.extractedCode.isEmpty {
                    KMono(text: "no code extracted.", size: 12, color: T.ink3).padding()
                } else {
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: 0) {
                            SyntaxHighlightedText(
                                code: result.extractedCode,
                                language: detectLanguage(result.extractedCode)
                            )
                            if result.isStreaming {
                                StreamingCaret()
                                    .padding(.top, 2)
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: StudioRadius.panel).fill(T.surface)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: StudioRadius.panel).stroke(T.rule, lineWidth: 1)
                        )

                        if !result.isStreaming {
                            Button { showCodeEditor = true } label: {
                                Image(systemName: "pencil").accessibilityLabel("Edit code")
                                    .font(.system(size: 11))
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: StudioRadius.panel).fill(T.surface2))
                                    .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel).stroke(T.rule, lineWidth: 1))
                                    .foregroundColor(T.ink2)
                            }
                            .padding(8)
                        }
                    }
                }
            }
            .padding()
        }
    }

    private var reviewTab: some View {
        ScrollView {
            if result.reviewMarkdown.isEmpty {
                Text("No review available.").foregroundColor(.secondary).padding()
            } else {
                MarkdownTextView(markdown: result.reviewMarkdown).padding()
            }
        }
    }

    /// Review tab + Q&A exchanges + ask bar. Used in Code mode tab 1.
    private var reviewWithQATab: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !result.reviewMarkdown.isEmpty {
                        MarkdownTextView(markdown: result.reviewMarkdown)
                    } else if result.questionAnswers.isEmpty {
                        Text("No review available. Ask a question below to analyse this capture further.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink3)
                    }
                    ForEach(result.questionAnswers) { qa in
                        qaBubble(qa)
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded { questionFocused = false }
            )
            askQuestionBar
        }
    }

    private func detectLanguage(_ code: String) -> String {
        let l = code.lowercased()
        if l.contains("func ") && (l.contains("var ") || l.contains("let ")) { return "Swift" }
        if l.contains("def ") || (l.contains("import ") && l.contains(":")) { return "Python" }
        if l.contains("const ") || l.contains("=>") { return "JavaScript" }
        if l.contains("#include") { return "C/C++" }
        return "Code"
    }

    // MARK: - Suggested action button
    //
    // Inline button that lets the user fix the underlying issue
    // (no visual model picked, FastVLM disabled, etc.) in a single
    // tap rather than reading the banner, dismissing the panel,
    // navigating to settings, finding the right toggle, and so on.

    @ViewBuilder
    private func suggestedActionButton(_ action: AnalysisResult.SuggestedAction) -> some View {
        let (label, icon, tint): (String, String, Color) = {
            switch action {
            case .pickVisualModel: return ("Pick visual model",   "checkmark.circle",       T.accent)
            case .downloadFastVLM: return ("Download FastVLM",    "arrow.down.circle",      T.accent)
            case .enableFastVLM:   return ("Enable in Settings",  "gearshape",              T.accent)
            }
        }()
        Button {
            HapticManager.impact(.light)
            handleSuggestedAction(action)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(label)
                    .font(T.mono(11, .semibold))
                    .tracking(0.3)
            }
            .foregroundColor(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).stroke(tint.opacity(0.40), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func handleSuggestedAction(_ action: AnalysisResult.SuggestedAction) {
        switch action {
        case .pickVisualModel:
            // Present the picker inline as a sheet on the panel —
            // keeps the user in context (didn't dismiss their result)
            // and avoids tab-hopping. Once they commit a pick, the
            // sheet closes; the next capture uses the new model.
            showModelPickerSheet = true

        case .downloadFastVLM:
            // Switch to Models tab; the FastVLM entry's Download
            // button is the next tap. Dismiss the panel so the user
            // sees the tab change immediately.
            isPresented = false
            bridge.requestTab(.models)

        case .enableFastVLM:
            // Settings is reachable from the Models tab via the gear
            // icon. Surface that route by switching there and let the
            // user open Settings themselves. (We don't have a global
            // "present Settings sheet" hook from arbitrary contexts.)
            isPresented = false
            bridge.requestTab(.models)
        }
    }
}

// MARK: - StreamingCaret
// Blinking caret shown while FastVLM is generating.

struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.koduTheme) private var T
    @ScaledMetric(relativeTo: .body) private var caretHeight: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: reduceMotion || scenePhase != .active)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * .pi * 2 / 1.2
            RoundedRectangle(cornerRadius: StudioRadius.panel)
                .fill(T.ink)
                .frame(width: 2, height: caretHeight)
                .opacity(reduceMotion ? 0.65 : 0.35 + 0.65 * (sin(phase) + 1) / 2)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - BlinkModifier
// Subtle pulse for status dots while a stream is in progress.

struct BlinkModifier: ViewModifier {
    @State private var faded = false
    func body(content: Content) -> some View {
        content
            .opacity(faded ? 0.35 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                    faded.toggle()
                }
            }
    }
}

// MARK: - ShareSheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - MarkdownTextView (unchanged — kept here for co-location)

struct MarkdownTextView: View {
    let markdown: String
    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in block }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnyView] {
        StudioTextBlocks.parse(markdown).flatMap { block -> [AnyView] in
            switch block {
            case .code(let language, let code):
                return [AnyView(CodeBlock(language: language, code: code))]
            case .thinking(let text, let open):
                return [AnyView(ThinkingBlock(content: text, isOpen: open))]
            case .math(let source):
                return [AnyView(MathBlock(latex: source))]
            case .text(let text):
                return text.components(separatedBy: "\n").map { AnyView(renderLine($0)) }
            }
        }
    }

    @ViewBuilder
    private func renderLine(_ line: String) -> some View {
        if line.hasPrefix("# ") {
            Text(String(line.dropFirst(2)))
                .font(T.sans(20, .semibold))
                .tracking(-0.5)
                .foregroundColor(T.ink)
                .padding(.top, 8)
        } else if line.hasPrefix("## ") {
            Text(String(line.dropFirst(3)))
                .font(T.sans(16, .semibold))
                .foregroundColor(T.ink)
                .padding(.top, 6)
        } else if line.hasPrefix("### ") {
            Text(String(line.dropFirst(4)))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
        } else if line.hasPrefix("**") && line.hasSuffix("**") && line.count > 4 {
            Text(String(line.dropFirst(2).dropLast(2)))
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .top, spacing: 6) {
                Text("·").foregroundColor(T.ink3)
                Text(String(line.dropFirst(2)))
                    .font(T.sans(13))
                    .foregroundColor(T.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if line.hasPrefix("> ") {
            Text(String(line.dropFirst(2)))
                .font(T.mono(11))
                .foregroundColor(T.ink2)
                .padding(.leading, 10)
                .overlay(Rectangle().fill(T.warn.opacity(0.6)).frame(width: 2), alignment: .leading)
        } else if line.isEmpty {
            Spacer().frame(height: 4)
        } else {
            Text(line)
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
