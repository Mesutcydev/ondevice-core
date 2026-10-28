import SwiftUI
import ImageIO
import UIKit

/// Shared production and preview composer. Files and submission acceptance remain host-owned.
public struct ODComposer: View {
    @Binding private var text: String
    private var focus: FocusState<Bool>.Binding
    private let attachments: [ODAttachment]
    private let isResponding: Bool
    private let canSend: Bool
    private let canStop: Bool
    private let canAdd: Bool
    private let canRemove: Bool
    private let microphone: AnyView?
    private let notice: AnyView?
    private let modelControl: AnyView?
    private let onAdd: () -> Void
    private let onRemove: (String) -> Void
    private let onSend: (String, [String]) -> Void
    private let onStop: () -> Void
    private let onVoice: (() -> Void)?
    private let thinking: Bool?
    private let onThinking: ((Bool) -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var glyphSize = ODLayout.standardIcon
    private let writingHorizontalInset = ODLayout.textAdditionalHorizontalInset

    public init(text: Binding<String>, focus: FocusState<Bool>.Binding,
                attachments: [ODAttachment], isResponding: Bool,
                canSend: Bool, canStop: Bool, canAdd: Bool, canRemove: Bool,
                microphone: AnyView? = nil, notice: AnyView? = nil, modelControl: AnyView? = nil,
                onVoice: (() -> Void)? = nil,
                thinking: Bool? = nil, onThinking: ((Bool) -> Void)? = nil,
                onAdd: @escaping () -> Void, onRemove: @escaping (String) -> Void,
                onSend: @escaping (String, [String]) -> Void, onStop: @escaping () -> Void) {
        self._text = text
        self.focus = focus
        self.attachments = attachments
        self.isResponding = isResponding
        self.canSend = canSend
        self.canStop = canStop
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.microphone = microphone
        self.notice = notice
        self.modelControl = modelControl
        self.onAdd = onAdd
        self.onRemove = onRemove
        self.onSend = onSend
        self.onStop = onStop
        self.onVoice = onVoice
        self.thinking = thinking
        self.onThinking = onThinking
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            if let notice {
                notice
            }
            VStack(alignment: .leading, spacing: 0) {
                if let modelControl {
                    HStack(spacing: ODLayout.elementGap) {
                        modelControl
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, writingHorizontalInset)
                    .padding(.bottom, ODLayout.elementGap)
                }
                if !attachments.isEmpty {
                    attachmentStrip
                        .padding(.horizontal, writingHorizontalInset)
                        .padding(.bottom, ODLayout.composerAttachmentGap)
                }
                if modelControl != nil && !dynamicType.isAccessibilitySize {
                    HStack(alignment: .bottom, spacing: ODLayout.unit) {
                        addButton
                        if let thinking, let onThinking {
                            thinkingButton(isOn: thinking, onToggle: onThinking)
                        }
                        writingField.padding(.vertical, ODLayout.elementGap)
                        actionControls
                    }
                    .frame(minHeight: ODLayout.minimumHit)
                } else {
                    writingField
                        .padding(.horizontal, writingHorizontalInset)
                        .padding(.bottom, ODLayout.composerFooterGap)
                    footer
                }
            }
            .padding(.horizontal, ODLayout.composerSideInset)
            .padding(.top, ODLayout.composerTopInset)
            .padding(.bottom, ODLayout.composerBottomInset)
            .frame(maxWidth: .infinity, minHeight: ODLayout.composerMinimumHeight)
            // Any tap on the card that no control claims focuses the text.
            .contentShape(composerShape)
            .onTapGesture { focus.wrappedValue = true }
            .glassEffect(.regular, in: composerShape)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.composer.panel")
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: text)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: attachments.isEmpty)
        }
        .padding(.horizontal, ODLayout.pageInset)
        .padding(.top, ODLayout.elementGap)
        .padding(.bottom, ODLayout.composerInputStackGap)
    }

    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ODLayout.composerCorner, style: .continuous)
    }

    private var prompt: Text {
        Text("Message", bundle: .module).foregroundStyle(ODPalette.secondary)
    }

    private var writingField: some View {
        TextField("Message", text: $text, prompt: prompt, axis: .vertical)
            .font(.body)
            .foregroundStyle(ODPalette.text)
            .tint(ODPalette.text)
            .lineLimit(1...6)
            .submitLabel(.return)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .focused(focus)
            .accessibilityLabel(Text("Message", bundle: .module))
            .accessibilityIdentifier("chat.composer.text")
    }

    private var footer: some View {
        HStack(spacing: 0) {
            addButton
            if let thinking, let onThinking {
                thinkingButton(isOn: thinking, onToggle: onThinking)
            }
            Spacer(minLength: ODLayout.elementGap)
            actionControls
        }
        .frame(minHeight: ODLayout.minimumHit)
    }

    private var actionControls: some View {
        HStack(spacing: 0) {
            if microphone != nil {
                dictationControl
                primaryAction
                    .padding(.leading, ODLayout.composerMicPrimaryGap)
            } else {
                primaryAction
            }
            if isResponding {
                ODComposerPrimaryAction(symbol: "arrow.up", label: "Send message",
                    identifier: "chat.composer.send", isEnabled: false,
                    hapticStyle: .light, action: {})
                    .padding(.leading, ODLayout.unit)
            }
        }
    }

    /// A naked utility icon. The host view supplies the glyph and behaviour;
    /// no chrome is added here so it cannot compete with the primary action.
    @ViewBuilder private var dictationControl: some View {
        if let microphone {
            microphone
        }
    }

    private var addButton: some View {
        Button {
            ODComposerHaptics.impact(.light)
            onAdd()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: min(glyphSize, ODLayout.composerGlyphMaximum), weight: .medium))
                .foregroundStyle(ODPalette.secondary)
                .frame(width: ODLayout.minimumHit, height: ODLayout.minimumHit)
                .contentShape(Rectangle())
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(!canAdd)
        .accessibilityLabel(Text("Message tools and attachments", bundle: .module))
        .accessibilityIdentifier("chat.composer.add")
    }

    /// Same naked-glyph treatment as the add control; the filled glyph in ink
    /// marks the on state. Only shown for models whose reasoning can switch.
    private func thinkingButton(isOn: Bool, onToggle: @escaping (Bool) -> Void) -> some View {
        Button {
            ODComposerHaptics.impact(.light)
            onToggle(!isOn)
        } label: {
            Image(systemName: isOn ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: min(glyphSize, ODLayout.composerGlyphMaximum), weight: .medium))
                .foregroundStyle(isOn ? ODPalette.text : ODPalette.secondary)
                .frame(width: ODLayout.minimumHit, height: ODLayout.minimumHit)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(isResponding)
        .accessibilityLabel(Text("Thinking", bundle: .module))
        .accessibilityValue(Text(odKey: isOn ? "On" : "Off"))
        .accessibilityHint(Text("Reason step by step before answering", bundle: .module))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier("chat.composer.thinking")
    }

    private var offersVoice: Bool {
        !isResponding && attachments.isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && onVoice != nil
    }

    /// One anchored control, three semantic states: voice, send, stop.
    private var primaryAction: some View {
        ODComposerPrimaryAction(
            symbol: isResponding ? "stop.fill" : (offersVoice ? "waveform" : "arrow.up"),
            label: isResponding ? "Stop response" : (offersVoice ? "Voice conversation" : "Send message"),
            identifier: isResponding ? "chat.composer.stop" : (offersVoice ? "chat.composer.voice" : "chat.composer.send"),
            isEnabled: isResponding ? canStop : (offersVoice || canSend),
            hapticStyle: isResponding ? .medium : .light
        ) {
            if isResponding { onStop() }
            else if offersVoice { onVoice?() }
            else { onSend(text, attachments.map(\.id)) }
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ODLayout.elementGap) {
                ForEach(attachments) { attachment in
                    ODComposerAttachment(attachment: attachment, canRemove: canRemove, onRemove: onRemove)
                }
            }
        }
        .scrollClipDisabled()
        .frame(height: ordinaryAttachmentRow ? ODLayout.minimumHit : nil)
        .accessibilityLabel(Text("Draft attachments", bundle: .module))
    }

    /// File tokens share a 44-point row. Image previews keep their own height.
    private var ordinaryAttachmentRow: Bool {
        !dynamicType.isAccessibilitySize && !attachments.contains { $0.kind == .image }
    }
}

/// The composer's single emphatic control. Its geometry never changes; only the
/// glyph and meaning move between voice, send and stop, so the trailing corner
/// stays anchored across states. Stop uses the reference's red fill and subtle glow.
private struct ODComposerPrimaryAction: View {
    let symbol: String
    let label: String
    let identifier: String
    let isEnabled: Bool
    let hapticStyle: UIImpactFeedbackGenerator.FeedbackStyle
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var glyphSize = 16

    var body: some View {
        Button {
            ODComposerHaptics.impact(hapticStyle)
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: min(glyphSize, ODLayout.composerSendDiameter / 2), weight: .semibold))
                .foregroundStyle(symbol == "stop.fill" ? Color.white : ODPalette.onSend)
                .frame(width: ODLayout.composerSendDiameter, height: ODLayout.composerSendDiameter)
                .background(symbol == "stop.fill" ? Color.red : ODPalette.send, in: Circle())
                .shadow(color: symbol == "stop.fill" ? .red.opacity(0.3) : .clear, radius: 8, y: 3)
                .frame(width: ODLayout.minimumHit, height: ODLayout.minimumHit)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(ODComposerPrimaryActionStyle())
        .disabled(!isEnabled)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: symbol)
        .accessibilityLabel(Text(odKey: label))
        .accessibilityIdentifier(identifier)
    }
}

private struct ODComposerPrimaryActionStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Restrained haptics for composer commitments only — never for text changes.
private enum ODComposerHaptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

/// Decode a bounded local thumbnail only when its bytes change, not on each keystroke.
private struct ODComposerAttachment: View {
    let attachment: ODAttachment
    let canRemove: Bool
    let onRemove: (String) -> Void
    @State private var preview: UIImage?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if attachment.kind == .image {
                ZStack {
                    ODPalette.input
                    if let preview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: typeSize.isAccessibilitySize ? 112 : 96, height: typeSize.isAccessibilitySize ? 112 : 96)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(alignment: .topTrailing) { removeButton(image: true) }
                .accessibilityIdentifier("chat.attachment.preview.\(attachment.id)")
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.body)
                        .foregroundStyle(ODPalette.secondary)
                        .accessibilityHidden(true)
                    Text(attachment.name).font(.footnote)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: ODLayout.attachmentNameMaximumWidth, alignment: .leading)
                    removeButton(image: false)
                }
                .padding(.leading, 12)
                .frame(minHeight: ODLayout.minimumHit)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(ODPalette.text.opacity(0.065))
                        .frame(height: typeSize.isAccessibilitySize ? nil : ODLayout.composerAttachmentFaceHeight)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Attachment: \(attachment.name)", bundle: .module))
        .task(id: attachment.previewData) {
            guard let data = attachment.previewData,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 336,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { preview = nil; return }
            preview = UIImage(cgImage: thumbnail)
        }
    }

    private func removeButton(image: Bool) -> some View {
        Button { onRemove(attachment.id) } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(image ? Color.white : ODPalette.secondary)
                .frame(width: 24, height: 24)
                .background(image ? Color.black.opacity(0.55) : .clear, in: Circle())
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!canRemove)
        .accessibilityLabel(Text("Remove \(attachment.name)", bundle: .module))
    }
}

/// Name and optional parameter token for the chat model pill. The full
/// name stays on the control’s accessibility value.
/// Runtime state behind the model picker's status dot.
public enum ODRuntimeStatus: Sendable { case idle, ready, working }

public struct ODModelMenuLabel: View {
    private let displayName: String
    private let metadata: String?
    private let preservesName: Bool
    private let conversationTitle: String?
    private let status: ODRuntimeStatus
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(displayName: String, metadata: String? = nil, preservesName: Bool = false,
                conversationTitle: String? = nil, status: ODRuntimeStatus = .idle) {
        self.status = status
        self.displayName = displayName
        self.metadata = metadata
        self.preservesName = preservesName
        self.conversationTitle = conversationTitle
    }

    public var body: some View {
        let face: (title: String, size: String?, accessibleName: String) = preservesName
            ? (displayName, nil, displayName)
            : ODPresentation.modelFace(displayName: displayName, metadata: metadata)
        HStack(spacing: 6) {
            if conversationTitle == nil { statusDot }
            VStack(alignment: conversationTitle == nil ? .leading : .center, spacing: 1) {
                if let conversationTitle, !typeSize.isAccessibilitySize {
                    Text(conversationTitle).font(.subheadline.weight(.semibold))
                        .foregroundStyle(ODPalette.text).lineLimit(1)
                }
                HStack(spacing: ODLayout.unit) {
                    if conversationTitle != nil { statusDot }
                    Text(odKey: face.title.isEmpty ? "Select model" : face.title)
                        .lineLimit(1).truncationMode(.tail)
                    if conversationTitle != nil, let size = face.size {
                        Text(size).lineLimit(1).layoutPriority(1)
                    }
                }
                .font(conversationTitle == nil ? .subheadline : .caption)
                .foregroundStyle(ODPalette.secondary)
            }
            if conversationTitle == nil, let size = face.size {
                Text(size)
                    .font(.footnote)
                    .foregroundStyle(ODPalette.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ODPalette.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minHeight: ODLayout.minimumHit)
        .glassEffect(.regular.interactive(), in: Capsule())
    }

    /// Green while weights are resident, pulsing while generating. The host's
    /// status strip carries the same state as text, so the dot stays hidden.
    private var statusDot: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(status == .idle ? ODPalette.secondary : Color.green)
            .symbolEffect(.pulse, isActive: status == .working)
            .accessibilityHidden(true)
    }
}

/// Leading keyboard-toolbar control. The toolbar supplies the only chrome.
/// Send owns the composer’s trailing edge.
public struct ODKeyboardDismissKey: View {
    private var focus: FocusState<Bool>.Binding
    private var clearance: ODComposerKeyboardClearance?
    public init(focus: FocusState<Bool>.Binding, clearance: ODComposerKeyboardClearance? = nil) {
        self.focus = focus
        self.clearance = clearance
    }
    public var body: some View {
        Button(ODLocalizedString("Hide keyboard"), systemImage: "keyboard.chevron.compact.down") {
            focus.wrappedValue = false
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .foregroundStyle(ODPalette.secondary)
        .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
        .accessibilityIdentifier("keyboard.dismiss")
        .background {
            if let clearance {
                ODGlobalEdgeReader(edge: .top) { clearance.setButtonTop($0) }
            }
        }
        .onDisappear { clearance?.setButtonTop(nil) }
    }
}

/// Lifts the composer by the measured overlap of the keyboard-toolbar
/// control. The gap under the card is `composerInputStackGap`; this
/// object only removes the part of the toolbar that draws through it.
@MainActor
public final class ODComposerKeyboardClearance: ObservableObject {
    @Published public private(set) var lift: CGFloat = 0
    private var dockBottom: CGFloat?
    private var buttonTop: CGFloat?
    private var settledLift: CGFloat = 0
    private var settleTask: Task<Void, Never>?

    public init() {}

    public func setDockBottom(_ y: CGFloat) {
        guard y > 1, y < 20_000 else { return }
        guard dockBottom.map({ abs($0 - y) > 0.5 }) ?? true else { return }
        dockBottom = y
        schedule()
    }

    public func setButtonTop(_ y: CGFloat?) {
        guard let y, y > 1, y < 20_000 else {
            settleTask?.cancel()
            buttonTop = nil
            if lift != 0 { lift = 0 }
            return
        }
        let appeared = buttonTop == nil
        guard buttonTop.map({ abs($0 - y) > 0.5 }) ?? true else { return }
        buttonTop = y
        if appeared, lift == 0, settledLift > 0.5 {
            lift = settledLift
        }
        schedule()
    }

    /// Wait until the keyboard animation stops reporting, then correct once.
    private func schedule() {
        settleTask?.cancel()
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            apply()
        }
    }

    private func apply() {
        guard let dock = dockBottom, let button = buttonTop else { return }
        guard let next = Self.nextLift(current: lift, dockBottom: dock, buttonTop: button) else {
            if lift != 0 { lift = 0 }
            return
        }
        guard abs(next - lift) > 1 else {
            settledLift = lift
            return
        }
        lift = next
    }

    /// Extra points under the composer. Nil when the control is not the
    /// bottom input stack (a floating keyboard far from the dock).
    public static func nextLift(current: CGFloat, dockBottom: CGFloat, buttonTop: CGFloat) -> CGFloat? {
        let error = dockBottom - buttonTop
        guard abs(error) <= 120 else { return nil }
        return min(96, max(0, current + error))
    }
}

/// Reads one edge in the global coordinate space. The composer dock and the
/// keyboard-toolbar control both use it.
public struct ODGlobalEdgeReader: View {
    public enum Edge { case top, bottom }
    var edge: Edge
    var onChange: (CGFloat) -> Void

    public init(edge: Edge, onChange: @escaping (CGFloat) -> Void) {
        self.edge = edge
        self.onChange = onChange
    }

    public var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let y = edge == .top ? frame.minY : frame.maxY
            Color.clear
                .onAppear { onChange(y) }
                .onChange(of: y) { _, newValue in onChange(newValue) }
        }
        .allowsHitTesting(false)
    }
}

/// Composer dock plus the measured clearance under it.
public struct ODComposerKeyboardSlot<Content: View>: View {
    @ObservedObject private var clearance: ODComposerKeyboardClearance
    private var content: Content

    public init(clearance: ODComposerKeyboardClearance, @ViewBuilder content: () -> Content) {
        self.clearance = clearance
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            content
                .background {
                    ODGlobalEdgeReader(edge: .bottom) { clearance.setDockBottom($0) }
                }
            Color.clear
                .frame(height: clearance.lift)
                .accessibilityHidden(true)
        }
    }
}

/// Right-align natural content while enforcing the documented 82% width cap.
public struct ODUserBubbleLayout: Layout {
    public var displayScale: CGFloat
    public init(displayScale: CGFloat) { self.displayScale = displayScale }
    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width ?? content.sizeThatFits(.unspecified).width
        let cap = ODLayout.maxUserBubbleWidth(contentWidth: width, displayScale: displayScale)
        let measured = content.sizeThatFits(ProposedViewSize(width: cap, height: nil))
        return CGSize(width: width, height: measured.height)
    }
    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let cap = ODLayout.maxUserBubbleWidth(contentWidth: bounds.width, displayScale: displayScale)
        let measured = content.sizeThatFits(ProposedViewSize(width: cap, height: nil))
        content.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing,
                      proposal: ProposedViewSize(width: min(cap, measured.width), height: measured.height))
    }
}
