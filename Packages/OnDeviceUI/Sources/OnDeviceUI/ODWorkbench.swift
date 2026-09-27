import SwiftUI

/// A single workspace canvas with a leading sidebar and contextual secondary sheets.
/// The host owns inference, permissions, files, microphone and camera lifecycle.
@MainActor
public struct OnDeviceWorkbench: View {
    @ObservedObject private var store: ODStore
    private let cameraPreview: AnyView?
    private let lensResultContent: ((Binding<Bool>) -> AnyView)?
    private let chatContent: AnyView?
    private let settingsContent: AnyView?
    private let imageContent: AnyView?
    private let deviceContent: AnyView?
    private let apiServerContent: AnyView?
    private let voiceContent: AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var visited: Set<ODTab> = []
    /// Animated mirror of `store.conversationsPresented`: every open/close runs
    /// one spring, and the drawer stays mounted until its close has finished.
    @State private var drawerOpen = false
    @State private var drawerMounted = false
    @GestureState(resetTransaction: Transaction(animation: OnDeviceWorkbench.drawerSpring))
    private var drawerDrag: CGFloat = 0

    /// Critically damped and a touch slower than a push: the workspace should
    /// feel weighty as it slides onto its card, then settle without a wobble.
    static let drawerSpring: Animation = .spring(response: 0.44, dampingFraction: 0.9)
    /// Close to the iPhone display radius, so the card reads as the screen itself
    /// sliding aside (the reference drawer), not a panel with small corners.
    private static let cardCorner: CGFloat = 55

    public init(store: ODStore, cameraPreview: AnyView? = nil,
                chatContent: AnyView? = nil, settingsContent: AnyView? = nil,
                imageContent: AnyView? = nil, deviceContent: AnyView? = nil,
                voiceContent: AnyView? = nil, apiServerContent: AnyView? = nil,
                lensResultContent: ((Binding<Bool>) -> AnyView)? = nil) {
        self.store = store
        self.cameraPreview = cameraPreview
        self.lensResultContent = lensResultContent
        self.chatContent = chatContent
        self.settingsContent = settingsContent
        self.imageContent = imageContent
        self.deviceContent = deviceContent
        self.apiServerContent = apiServerContent
        self.voiceContent = voiceContent
    }

    public var body: some View {
        GeometryReader { geometry in
            let width = dynamicTypeSize.isAccessibilitySize
                ? min(480, max(0, geometry.size.width - 24))
                : ODLayout.drawerWidth(availableWidth: geometry.size.width)
            let offset = min(width, max(0, (drawerOpen ? width : 0) + drawerDrag))
            let progress = width > 0 ? offset / width : 0
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            ZStack(alignment: .leading) {
                if drawerMounted || drawerDrag > 0 {
                    ODConversationDrawer()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        // Parallax: the drawer eases in from a quarter of its width
                        // behind the moving workspace instead of sitting static.
                        .offset(x: reduceMotion ? 0 : -(1 - progress) * width * 0.25 * direction)
                        .opacity(reduceMotion ? (drawerOpen ? 1 : 0) : 0.35 + 0.65 * progress)
                        .accessibilityHidden(!store.conversationsPresented)
                        .allowsHitTesting(store.conversationsPresented)
                        .accessibilityAction(.escape) { store.conversationsPresented = false }
                        .simultaneousGesture(drawerGesture(width: width, direction: direction))
                }
                primaryWorkspace
                    .background { ODPageBackground().ignoresSafeArea() }
                    .overlay {
                        // No dimming: the card keeps full brightness, as in the
                        // reference. Tapping anywhere on it closes the drawer.
                        if store.conversationsPresented {
                            Button { store.conversationsPresented = false } label: {
                                Color.clear.contentShape(Rectangle())
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close app menu")
                                .accessibilityIdentifier("navigation.dismissMenu")
                                .gesture(drawerGesture(width: width, direction: direction))
                        }
                    }
                    // The workspace becomes a full-height card: continuous corners
                    // round in over the first part of the slide. The mask reaches
                    // into the status-bar and home-indicator areas so the card's
                    // corners sit at the screen edges, not the safe-area edges.
                    .mask {
                        RoundedRectangle(cornerRadius: Self.cardCorner * min(1, progress * 3), style: .continuous)
                            .padding(.top, -geometry.safeAreaInsets.top)
                            .padding(.bottom, -geometry.safeAreaInsets.bottom)
                    }
                    .overlay {
                        // Hairline edge only in OLED, where card and drawer are
                        // both black; elsewhere the card's own color separates it.
                        RoundedRectangle(cornerRadius: Self.cardCorner * min(1, progress * 3), style: .continuous)
                            .strokeBorder(store.appearance == .oled ? ODPalette.line : .clear, lineWidth: 1)
                            .padding(.top, -geometry.safeAreaInsets.top)
                            .padding(.bottom, -geometry.safeAreaInsets.bottom)
                            .opacity(progress)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    .shadow(color: .black.opacity(0.22 * progress), radius: 30, x: -8 * direction)
                    .offset(x: reduceMotion ? (drawerOpen ? width * direction : 0) : offset * direction)
                    .zIndex(1)
                // The menu-dismiss button remains accessible while the workspace beneath is hidden.
                if !store.conversationsPresented {
                    Color.clear.frame(width: 20)
                        .contentShape(Rectangle())
                        .gesture(drawerGesture(width: width, direction: direction))
                        .accessibilityHidden(true)
                        .zIndex(2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The drawer's backdrop sits behind the card, so its rounded corners
        // cut out to the drawer color instead of vanishing into the page color.
        .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        .environmentObject(store)
        .preferredColorScheme(store.appearance.colorScheme)
        .environment(\.odAppearance, store.appearance)
        .onChange(of: store.conversationsPresented, initial: true) { _, presented in
            if presented { drawerMounted = true }
            withAnimation(reduceMotion ? ODMotion.fade : Self.drawerSpring) {
                drawerOpen = presented
            } completion: {
                if !store.conversationsPresented { drawerMounted = false }
            }
        }
        .sensoryFeedback(.impact(weight: .light, intensity: 0.55), trigger: store.conversationsPresented)
        .onChange(of: store.selectedTab, initial: true) { _, destination in
            visited.insert(destination)
        }
        .onChange(of: store.secondaryRoute, initial: true) { _, route in
            if route == .imageStudio || route == .device {
                store.selectedTab = route == .imageStudio ? .imageStudio : .device
                store.secondaryRoute = nil
            }
        }
        .sheet(item: Binding(get: { store.secondaryRoute == .settings ? store.secondaryRoute : nil },
                             set: { store.secondaryRoute = $0 }),
               onDismiss: { store.completeVoiceReturnAfterSheetDismissal() }) { route in
            secondaryWorkspace(route)
                .environmentObject(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .environment(\.odAppearance, store.appearance)
        }
        .confirmationDialog("End voice conversation?", isPresented: $store.interruptionConfirmationPresented, titleVisibility: .visible) {
            Button("End voice and continue", role: .destructive) { store.confirmInterruption() }
            Button("Keep voice conversation", role: .cancel) { store.cancelInterruption() }
        } message: {
            Text("\(store.interruptionReason) needs the shared model or microphone. Your voice conversation will end before continuing.")
        }
        .fullScreenCover(isPresented: $store.voiceSessionPresented) {
            voiceWorkspace
                .environmentObject(store)
                .preferredColorScheme(store.appearance.colorScheme)
                .environment(\.odAppearance, store.appearance)
                .interactiveDismissDisabled(store.voiceSessionActive)
        }
    }

    private var primaryWorkspace: some View {
        // Keep visited screens mounted. The host transcript owns unsent attachments,
        // request lifetime and reading position in @State; a switch would destroy them.
        // The same selection publisher still drives all host camera/audio cleanup.
        ZStack {
            retained(.home) { ODConversationsHome() }
            retained(.chat) { chatWorkspace }
            retained(.lens) {
                ODLensView(preview: cameraPreview ?? AnyView(ODCameraPlaceholder()), resultContent: lensResultContent)
            }
            retained(.voice) { ODVoiceLibraryView() }
            retained(.models) { ODModelsView() }
            retained(.imageStudio) {
                if let imageContent { imageContent } else { ODImageStudioView() }
            }
            retained(.apiServer) {
                if let apiServerContent { apiServerContent }
            }
            retained(.device) {
                if let deviceContent { deviceContent } else { ODSystemView() }
            }
        }
        .accessibilityHidden(store.conversationsPresented)
        .allowsHitTesting(!store.conversationsPresented)
    }

    @ViewBuilder private func retained<Content: View>(_ destination: ODTab, @ViewBuilder content: () -> Content) -> some View {
        if visited.contains(destination) || store.selectedTab == destination {
            content()
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if [.models, .device, .apiServer].contains(destination) {
                        ODWorkspaceBottomBar { EmptyView() }
                    }
                }
                .environment(\.odWorkspaceVisible, store.selectedTab == destination && !store.conversationsPresented && store.secondaryRoute == nil)
                .animation(ODMotion.fade) { $0.opacity(store.selectedTab == destination ? 1 : 0) }
                .allowsHitTesting(store.selectedTab == destination)
                .accessibilityHidden(store.selectedTab != destination)
                .zIndex(store.selectedTab == destination ? 1 : 0)
        }
    }

    private func drawerGesture(width: CGFloat, direction: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($drawerDrag) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = value.translation.width * direction
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let projected = (store.conversationsPresented ? width : 0) + value.predictedEndTranslation.width * direction
                store.conversationsPresented = projected > width * 0.5
            }
    }

    @ViewBuilder private var chatWorkspace: some View {
        if let chatContent { chatContent } else { ODChatView() }
    }

    @ViewBuilder private var voiceWorkspace: some View {
        if let voiceContent { voiceContent } else { ODVoiceSessionView() }
    }

    @ViewBuilder private func secondaryWorkspace(_ route: ODSecondaryRoute) -> some View {
        switch route {
        case .imageStudio:
            if let imageContent { imageContent } else { ODImageStudioView() }
        case .device:
            if let deviceContent { deviceContent } else { ODSystemView() }
        case .settings:
            Group {
                if let settingsContent { settingsContent } else { ODSettingsView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { ODWorkspaceBottomBar { EmptyView() } }
        }
    }


}

/// The fallback communicates the absent host camera. It never opens a device camera.
private struct ODCameraPlaceholder: View {
    var body: some View {
        ZStack {
            ODPalette.graphite
            VStack(spacing: ODLayout.labelGap) {
                Image(systemName: "camera")
                    .font(.largeTitle.weight(.light))
                Text("Camera preview unavailable")
                    .font(.headline)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(ODPalette.ivory.opacity(0.7))
            .padding(ODLayout.groupGap)
        }
        .accessibilityElement(children: .combine)
    }
}
