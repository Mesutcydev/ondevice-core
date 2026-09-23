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
    @GestureState private var drawerDrag: CGFloat = 0

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
            let offset = min(width, max(0, (store.conversationsPresented ? width : 0) + drawerDrag))
            let direction: CGFloat = layoutDirection == .rightToLeft ? -1 : 1
            ZStack(alignment: .leading) {
                if store.conversationsPresented || drawerDrag > 0 {
                    ODConversationDrawer()
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .accessibilityAction(.escape) { store.conversationsPresented = false }
                        .simultaneousGesture(drawerGesture(width: width, direction: direction))
                }
                primaryWorkspace
                    .background { ODPageBackground().ignoresSafeArea() }
                    .overlay {
                        if store.conversationsPresented {
                            Button { store.conversationsPresented = false } label: {
                                Rectangle().fill(ODPalette.background.opacity(0.45))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Close app menu")
                                .accessibilityIdentifier("navigation.dismissMenu")
                                .gesture(drawerGesture(width: width, direction: direction))
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: offset > 0 ? 36 : 0))
                    .shadow(color: .black.opacity(offset > 0 ? 0.12 : 0), radius: 18, x: -6)
                    .offset(x: reduceMotion ? (store.conversationsPresented ? width * direction : 0) : offset * direction)
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
        .background { ODPageBackground().ignoresSafeArea() }
        .environmentObject(store)
        .preferredColorScheme(store.appearance.colorScheme)
        .environment(\.odAppearance, store.appearance)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 1), value: store.conversationsPresented)
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
                .opacity(store.selectedTab == destination ? 1 : 0)
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
