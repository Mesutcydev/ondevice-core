// Adapted from the owner-supplied Token AI Classifier's MachineStage/HangingTicket.
// The mouth mask, overlap, feed spring, sway keyframes and print ticks are unchanged.
import SwiftUI
import OnDeviceUI

struct ClassifierPrintStage: View {
    let phase: CoreAIClassifierWorkbench.Phase
    let isLoaded: Bool
    let result: ClassifierPrintedResult?
    let isStale: Bool
    let isWatching: Bool
    let onActivate: () -> Void
    let onOpenTicket: (ClassifierPrintedResult) -> Void
    @State private var printedResultID: UUID?
    @State private var reaction = 0
    @State private var availableWidth: CGFloat = 320
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale

    private var mood: ClassifierMachineMood {
        switch phase {
        case .loading: .waking
        case .running, .stopping: .reading
        case .failed: .puzzled
        default: isLoaded ? .awake : .asleep
        }
    }

    var body: some View {
        let focused = isWatching && !typeSize.isAccessibilitySize
        let width: CGFloat = focused ? 96 : min(232, availableWidth * 0.75)
        let ticketWidth = typeSize.isAccessibilitySize ? availableWidth : width * ClassifierMachine.mouthWidth - 8
        let belowMouth = width * ClassifierMachine.aspect * (1 - ClassifierMachine.mouthCenter)
        VStack(spacing: 16) {
            VStack(spacing: -belowMouth) {
                Button {
                    onActivate()
                    if mood != .asleep { reaction += 1 }
                } label: {
                    ClassifierMachine(mood: mood, width: width, isWatching: isWatching, reaction: reaction)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("classifier.machine")
                .accessibilityHint(mood == .asleep ? Text("Loads the selected model") : Text("Classifier status"))

                ZStack(alignment: .top) {
                    if let result, !focused {
                        let decision = ClassifierTicketDecision(result, locale: locale)
                        Button { onOpenTicket(result) } label: {
                            ClassifierHangingTicket(result: result, isStale: isStale,
                                celebrates: result.id != printedResultID, onPrinted: { printedResultID = result.id })
                        }
                            .buttonStyle(.plain)
                            .frame(width: ticketWidth)
                            .contextMenu {
                                ShareLink(item: ClassifierResultExport.json(result.answer,
                                    modelID: result.model.id, elapsedSeconds: result.elapsedSeconds))
                                Button("Result details", systemImage: "doc.text.magnifyingglass") { onOpenTicket(result) }
                            }
                            // Clipped dotted leaders must not enlarge the ticket's hit/VoiceOver frame.
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityLabel(result.answer.choice != nil || result.answer.score != nil
                                ? Text(decision.title) : Text(odKey: decision.title))
                            .accessibilityValue([decision.probability.map { $0.formatted(.percent.precision(.fractionLength(1)).locale(locale)) },
                                result.model.name].compactMap { $0 }.formatted(.list(type: .and).locale(locale)))
                            .accessibilityHint(isStale ? Text("This result belongs to the previous input.") : Text("Shows all scores and execution details"))
                            .accessibilityIdentifier("classifier.ticket")
                            .id(result.id)
                            .transition(reduceMotion ? .opacity : .move(edge: .top))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: belowMouth, alignment: .top)
                .mask(alignment: .top) {
                    Rectangle().padding(.horizontal, -60).padding(.bottom, -60)
                }
            }
            .overlay(alignment: .top) {
                Color.clear
                    .frame(width: width, height: width * ClassifierMachine.aspect * ClassifierMachine.mouthCenter)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onActivate()
                        if mood != .asleep { reaction += 1 }
                    }
                    .accessibilityHidden(true)
            }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.75, dampingFraction: 0.86), value: result?.id)
            if result != nil, isStale, !focused {
                Label("Input changed — classify again for a new result.", systemImage: "arrow.clockwise")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("classifier.staleResult")
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.85), value: focused)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isStale)
        .onChange(of: result?.id) { _, id in if id != nil { reaction += 1 } }
    }
}

private struct ClassifierHangingTicket: View {
    let result: ClassifierPrintedResult
    let isStale: Bool
    let onPrinted: () -> Void
    @State private var celebrates: Bool
    @State private var swing = 0
    @State private var tick = 0
    @State private var printStarted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.odWorkspaceVisible) private var workspaceVisible
    @Environment(\.scenePhase) private var scenePhase

    init(result: ClassifierPrintedResult, isStale: Bool, celebrates: Bool, onPrinted: @escaping () -> Void) {
        self.result = result; self.isStale = isStale; self.onPrinted = onPrinted
        _celebrates = State(initialValue: celebrates)
    }

    var body: some View {
        ClassifierResultTicket(result: result, isStale: isStale, animated: celebrates)
            .keyframeAnimator(initialValue: 0.0, trigger: swing) { content, angle in
                content.rotationEffect(.degrees(reduceMotion ? 0 : angle), anchor: .top)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(0, duration: 0.45)
                    SpringKeyframe(2.4, duration: 0.3, spring: .snappy)
                    SpringKeyframe(-1.5, duration: 0.35, spring: .snappy)
                    SpringKeyframe(0.6, duration: 0.35, spring: .snappy)
                    SpringKeyframe(0, duration: 0.5, spring: .smooth)
                }
            }
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.5), trigger: tick)
            .task(id: workspaceVisible && scenePhase == .active) {
                guard workspaceVisible, scenePhase == .active, celebrates, !printStarted else { return }
                printStarted = true
                onPrinted()
                guard !reduceMotion else { return }
                swing += 1
                for _ in 0..<5 {
                    guard !Task.isCancelled, workspaceVisible else { return }
                    tick += 1
                    do { try await Task.sleep(for: .milliseconds(80)) } catch { return }
                }
            }
    }
}
