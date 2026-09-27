import SwiftUI

/// The host supplies the preview and owns authorization, capture, photo import,
/// camera switching, and inference. Native iOS controls provide the chrome.
@MainActor
struct ODLensView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @FocusState private var questionFocused: Bool
    @State private var panelContentHeight: CGFloat = 74 * ODLayout.unit
    @State private var accessoryHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .title2) private var captureIconSize: CGFloat = 7 * ODLayout.unit
    @ScaledMetric(relativeTo: .title3) private var auxiliaryIconSide: CGFloat = 6 * ODLayout.unit
    private let preview: AnyView
    private let resultContent: ((Binding<Bool>) -> AnyView)?

    init(preview: AnyView, resultContent: ((Binding<Bool>) -> AnyView)? = nil) {
        self.preview = preview
        self.resultContent = resultContent
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .clipped()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        fittedCapturePanel(availableHeight: geometry.size.height, availableWidth: geometry.size.width)
                    }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .sheet(isPresented: $store.lensResultPresented) {
                if let resultContent { resultContent($store.lensResultPresented) }
                else { NavigationStack {
                    ScrollView {
                        Text(store.lensResultText ?? "")
                            .font(.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ODLayout.pageInset)
                    }
                    .background { ODPageBackground().ignoresSafeArea() }
                    .navigationTitle(store.cameraMode.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Done") { store.lensResultPresented = false } }
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: store.lensResultText ?? "") { Label("Share result", systemImage: "square.and.arrow.up") }
                        }
                    }
                }
            }
            }
            .onChange(of: store.conversationsPresented) { _, open in
                if open { questionFocused = false }
            }
            .onChange(of: store.selectedTab) { _, destination in
                if destination != .lens { questionFocused = false }
            }
            .navigationTitle("Lens")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton {
                        questionFocused = false
                        store.conversationsPresented = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityIdentifier("navigation.menu")
                }
                if store.capabilities.canConfigureLens {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("Lens options", systemImage: "ellipsis") {
                            Button("Prompt and capture options", systemImage: "slider.horizontal.3") { store.send(.showLensOptions) }
                            if store.capabilities.canViewLensHistory {
                                Button("Capture history", systemImage: "clock") { store.send(.showLensHistory) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .disabled(!store.canPerformActions)
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ODKeyboardDismissKey(focus: $questionFocused)
                    Spacer(minLength: 0)
                }
            }
        }
        .tint(ODPalette.text)
    }

    private var modelSelector: some View {
        Button {
            store.send(.selectLensModel)
        } label: {
            HStack(spacing: ODLayout.labelGap) {
                Image(systemName: "cube")
                    .font(.body)
                    .foregroundStyle(store.lensModelInstalled ? ODPalette.secondary : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: ODLayout.unit) {
                    // Eligibility decides the headline: a requirement never
                    // appears under a named, selectable model.
                    Text(store.lensModelInstalled
                         ? ODPresentation.modelName(store.lensModelName, compact: true)
                         : "Vision model required")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.lensModelInstalled ? store.lensModelStatus : "Choose a model to analyze images")
                        .font(.caption)
                        .foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if store.capabilities.canSelectLensModel {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ODPalette.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: ODLayout.minimumHit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!store.canPerformActions || !store.capabilities.canSelectLensModel || store.lensIsAnalyzing)
        .accessibilityLabel(store.lensModelInstalled ? "Vision model, \(store.lensModelName)" : "Vision model required")
        .accessibilityHint(store.capabilities.canSelectLensModel ? "Choose a vision model" : "Current vision model")
    }

    /// The panel keeps its intrinsic height, then scrolls if the keyboard,
    /// a short viewport, or accessibility text needs more room.
    private func fittedCapturePanel(availableHeight: CGFloat, availableWidth: CGFloat) -> some View {
        let reserve: CGFloat = questionFocused || dynamicTypeSize.isAccessibilitySize ? 0 : 120
        let maximumHeight = max(0, availableHeight - reserve)
        return VStack(spacing: 0) {
            ODVoiceSessionAccessory()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { accessoryHeight = $0 }
            ScrollView {
                capturePanel(availableWidth: ODLayout.contentWidth(availableWidth: availableWidth))
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: ODLensPanelHeightKey.self, value: geometry.size.height)
                        }
                    }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(panelContentHeight, max(0, maximumHeight - accessoryHeight)))
            .onPreferenceChange(ODLensPanelHeightKey.self) { height in
                // Sub-pixel oscillation between the measured content and the
                // clamped frame height loops the layout forever (the app never
                // idles). Ignore changes below half a point.
                if height > 0, abs(height - panelContentHeight) > 0.5 { panelContentHeight = height }
            }
        }
        .background(ODPalette.surface)
    }

    private func capturePanel(availableWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            modelSelector
            modeSelector(availableWidth: availableWidth).disabled(store.lensIsAnalyzing)

            TextField(
                store.cameraMode == .ask ? "Ask about this image…" : "Add instructions (optional)…",
                text: $store.lensQuestion,
                prompt: Text(store.cameraMode == .ask ? "Ask about this image…" : "Add instructions (optional)…")
                    .foregroundStyle(ODPalette.secondary),
                axis: .vertical
            )
            .font(.body)
            .foregroundStyle(ODPalette.text)
            .textFieldStyle(.plain)
            .lineLimit(1...3)
            .focused($questionFocused)
            .submitLabel(.done)
            .onSubmit { questionFocused = false }
            .accessibilityIdentifier("lens.instructions")
            .padding(ODLayout.labelGap)
            .frame(minHeight: ODLayout.minimumHit)
            .background(ODPalette.input, in: RoundedRectangle(cornerRadius: ODLayout.corner))
            .overlay {
                RoundedRectangle(cornerRadius: ODLayout.corner)
                    .strokeBorder(ODPalette.line, lineWidth: 1 / displayScale)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: ODLayout.corner))
            .onTapGesture { questionFocused = true }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("lens.instructions.container")
            .accessibilityLabel(store.cameraMode == .ask ? "Question about this image" : "Optional image instructions")
            .accessibilityHint(store.cameraMode.instruction)

            if let message = store.lensStatusMessage, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !store.capabilities.canCapture {
                Text("Camera capture is unavailable.")
                    .font(.footnote)
                    .foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.cameraNeedsSettings {
                Button("Open camera settings", systemImage: "gearshape") { store.send(.openCameraSettings) }
                    .buttonStyle(.glass)
            }
            if store.lensIsAnalyzing {
                HStack(spacing: ODLayout.elementGap) {
                    Text("Analyzing image").font(.footnote).foregroundStyle(.secondary).odShimmer()
                    Spacer(minLength: 0)
                    if store.capabilities.canCancelLensAnalysis {
                        Button("Stop", systemImage: "stop.fill") { store.send(.cancelLensAnalysis) }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Stop image analysis")
                    }
                }
            }
            if let result = store.lensResultText, !result.isEmpty {
                Button { store.lensResultPresented = true } label: {
                    HStack(alignment: .top) {
                        Text(result).font(.body).lineLimit(3).multilineTextAlignment(.leading)
                        Spacer(minLength: ODLayout.elementGap)
                        Image(systemName: "arrow.up.right")
                    }
                    .foregroundStyle(ODPalette.text)
                    .frame(minHeight: ODLayout.minimumHit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Read analysis result")
            }
            HStack(alignment: .top, spacing: 5 * ODLayout.unit) {
                auxiliaryControl(
                    symbol: "photo.on.rectangle", title: store.lensHasSelectedImage ? "Change" : "Photos", label: "Choose a photo",
                    enabled: store.capabilities.canChoosePhoto
                ) {
                    questionFocused = false
                    store.send(.openPhotoLibrary)
                }

                VStack(spacing: ODLayout.elementGap) {
                    Button {
                        questionFocused = false
                        if store.lensHasSelectedImage { store.send(store.lensModelInstalled ? .analyzeLens : .selectLensModel) }
                        else { store.send(.capture(mode: store.cameraMode, question: store.lensQuestion)) }
                    } label: {
                        Image(systemName: store.lensHasSelectedImage ? "arrow.up" : "camera.fill")
                            .font(.system(size: captureIconSize, weight: .medium))
                            .frame(width: captureIconSize + ODLayout.elementGap,
                                   height: captureIconSize + ODLayout.elementGap)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .odInkProminent()
                    .frame(minWidth: 15 * ODLayout.unit, minHeight: 15 * ODLayout.unit)
                    .disabled(!store.canPerformActions || store.lensIsAnalyzing || (!store.lensHasSelectedImage && !store.capabilities.canCapture))
                    .accessibilityLabel(store.lensHasSelectedImage ? (store.lensModelInstalled ? "Analyze selected image" : "Choose vision model") : "Capture image")
                    .accessibilityIdentifier("lens.primary")
                    .accessibilityHint(store.lensHasSelectedImage ? "Uses this reviewed image and your editable instructions" : "Takes a still image for review before analysis")
                    Text(store.lensHasSelectedImage ? (store.lensModelInstalled ? "Analyze" : "Choose model") : "Capture")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ODPalette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)

                if store.lensHasSelectedImage {
                    auxiliaryControl(symbol: "arrow.counterclockwise", title: "Retake", label: "Retake image", enabled: !store.lensIsAnalyzing) {
                        store.send(.retakeLens)
                    }
                } else if store.capabilities.canSwitchCamera {
                auxiliaryControl(
                    symbol: "arrow.triangle.2.circlepath.camera", title: "Switch", label: "Switch camera",
                    enabled: store.capabilities.canSwitchCamera
                ) {
                    questionFocused = false
                    store.send(.switchCamera)
                }
                } else if !dynamicTypeSize.isAccessibilitySize {
                    Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, ODLayout.gutter)
        .padding(.top, ODLayout.labelGap)
        .padding(.bottom, 4 * ODLayout.unit)
    }

    @ViewBuilder
    private func modeSelector(availableWidth: CGFloat) -> some View {
        if dynamicTypeSize >= .xxLarge || availableWidth < 76 * ODLayout.unit {
            modePicker
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
        } else {
            modePicker
                .pickerStyle(.segmented)
                .frame(minHeight: ODLayout.minimumHit)
        }
    }

    private var modePicker: some View {
        Picker("Lens mode", selection: $store.cameraMode) {
            ForEach(ODLensMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
    }

    private func auxiliaryControl(
        symbol: String, title: String, label: String, enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: ODLayout.elementGap) {
            Button(action: action) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: auxiliaryIconSide, height: auxiliaryIconSide)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .frame(minWidth: 15 * ODLayout.unit, minHeight: 15 * ODLayout.unit)
            .disabled(!store.canPerformActions || !enabled)
            .accessibilityLabel(label)
            Text(title)
                .font(.caption)
                .foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ODLensPanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
