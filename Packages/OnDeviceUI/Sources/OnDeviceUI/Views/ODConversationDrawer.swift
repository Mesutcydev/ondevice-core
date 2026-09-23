import SwiftUI

/// Workspace navigation with New chat and Settings anchored at the foot.
@MainActor
struct ODConversationDrawer: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let headerLayout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            headerLayout {
                Text("OnDevice").font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("sidebar.title")
                    .frame(maxWidth: .infinity, alignment: .leading)
                ODIconButton("magnifyingglass", label: "Search conversations") {
                    store.conversationsPresented = false
                    store.selectedTab = .home
                    store.chatSearchRequested = true
                }
            }
            .padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ODSidebarDestinations()
                }
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, -12)
            .scrollDismissesKeyboard(.interactively)
            ODVoiceSessionAccessory().padding(.horizontal, -ODLayout.pageInset)
            ODSidebarFooter()
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { ODPageBackground().ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App navigation")
        .accessibilityIdentifier("navigation.sidebar")
        .accessibilityAction(.escape) { store.conversationsPresented = false }
    }
}

@MainActor
private struct ODSidebarDestinations: View {
    @EnvironmentObject private var store: ODStore
    var body: some View {
        VStack(spacing: 0) {
            ODSidebarDestination(title: "Chats", symbol: "bubble.left.and.bubble.right",
                                 selected: store.selectedTab == .home, id: "home") { navigate(.home) }
            if store.hasOpenChat {
                ODSidebarDestination(title: store.selectedConversation?.title ?? "Open chat", symbol: "bubble.left",
                                     selected: store.selectedTab == .chat, id: "chat") { navigate(.chat) }
            }
            sectionTitle("Create")
            ODSidebarDestination(title: "Lens", symbol: "camera",
                                 selected: store.selectedTab == .lens, id: "lens") { navigate(.lens) }
            ODSidebarDestination(title: "Voice", symbol: "waveform",
                                 selected: store.selectedTab == .voice, id: "voice") { navigate(.voice) }
            ODSidebarDestination(title: "Image studio", symbol: "photo", selected: store.selectedTab == .imageStudio, id: "imageStudio") { navigate(.imageStudio) }
            sectionTitle("Manage")
            ODSidebarDestination(title: "Models", symbol: "cube",
                                 selected: store.selectedTab == .models, id: "models") { navigate(.models) }
            ODSidebarDestination(title: "Device", symbol: "iphone", selected: store.selectedTab == .device, id: "device") { navigate(.device) }
            if store.capabilities.canOpenAPIServer {
                ODSidebarDestination(title: "API server", symbol: "network", selected: store.selectedTab == .apiServer, id: "apiServer") {
                    navigate(.apiServer)
                }
            }
        }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, ODLayout.groupGap).padding(.bottom, ODLayout.elementGap)
            .accessibilityAddTraits(.isHeader)
    }
    private func navigate(_ destination: ODTab) {
        store.conversationsPresented = false
        store.selectedTab = destination
    }
}

private struct ODSidebarDestination: View {
    let title: String
    let symbol: String
    var selected = false
    let id: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconWidth = 24.0
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body).symbolVariant(.none).frame(width: iconWidth).accessibilityHidden(true)
                Text(title).font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(ODPalette.text)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(selected ? ODPalette.text.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(ODPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(id)")
        .padding(.horizontal, -12)
    }
}

@MainActor
private struct ODSidebarFooter: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 8))
        layout {
            Button {
                store.conversationsPresented = false
                store.selectedTab = .chat
                store.send(.newConversation)
            } label: {
                Label("New chat", systemImage: "square.and.pencil").font(.body.weight(.medium)).lineLimit(1)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
            .tint(.blue)
            .disabled(!store.canPerformActions || store.isResponding)
            .accessibilityLabel("New chat").accessibilityIdentifier("sidebar.newChat")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if typeSize.isAccessibilitySize {
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape").font(.body).lineLimit(1)
                }
                .buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
                .accessibilityIdentifier("sidebar.settings")
            } else {
                ODIconButton("gearshape", label: "Settings", action: openSettings)
                    .accessibilityIdentifier("sidebar.settings")
            }
        }
        .padding(.top, 8)
    }
    private func openSettings() {
        store.conversationsPresented = false
        store.selectedTab = .home
        store.secondaryRoute = .settings
    }
}
