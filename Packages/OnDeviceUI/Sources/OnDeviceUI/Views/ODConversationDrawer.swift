import SwiftUI

/// The leading drawer: brand and Settings at the head, workspaces as a compact
/// grid, recent chats as the body, Search and New chat at the foot.
@MainActor
struct ODConversationDrawer: View {
    @EnvironmentObject private var store: ODStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ODSidebarHeader()
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ODSidebarDestinations()
                    ODSidebarRecents()
                }
                .padding(.top, 20)
                .padding(.bottom, ODLayout.groupGap)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            ODVoiceSessionAccessory().padding(.horizontal, -ODLayout.pageInset)
            ODSidebarFooter()
        }
        .padding(.horizontal, 20).padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Grouped background (black in dark, soft grey in light) so the
        // workspace reads as a lighter card resting on the drawer.
        .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("App navigation")
        .accessibilityIdentifier("navigation.sidebar")
        .accessibilityAction(.escape) { store.conversationsPresented = false }
    }
}

@MainActor
private struct ODSidebarHeader: View {
    @EnvironmentObject private var store: ODStore
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("OnDevice")
                .font(.title.weight(.bold))
                .lineLimit(1).minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("sidebar.title")
                .frame(maxWidth: .infinity, alignment: .leading)
            ODIconButton("gearshape", label: "Settings") {
                store.conversationsPresented = false
                store.secondaryRoute = .settings
            }
            .accessibilityIdentifier("sidebar.settings")
        }
    }
}

/// Workspaces as tiles: every destination stays one tap away without pushing
/// the conversation list below the fold.
@MainActor
private struct ODSidebarDestinations: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var typeSize

    private var destinations: [(title: String, symbol: String, tab: ODTab, id: String)] {
        var items: [(title: String, symbol: String, tab: ODTab, id: String)] = [
            ("Lens", "camera", .lens, "lens"),
            ("Voice", "waveform", .voice, "voice"),
            ("Image studio", "photo", .imageStudio, "imageStudio"),
            ("Models", "cube", .models, "models"),
            ("Device", "iphone", .device, "device"),
        ]
        if store.capabilities.canOpenAPIServer { items.append(("API server", "network", .apiServer, "apiServer")) }
        return items
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: typeSize.isAccessibilitySize ? 1 : 3)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(destinations, id: \.id) { item in
                ODSidebarTile(title: item.title, symbol: item.symbol,
                              selected: store.selectedTab == item.tab, id: item.id) {
                    store.conversationsPresented = false
                    store.selectedTab = item.tab
                }
            }
        }
    }
}

private struct ODSidebarTile: View {
    let title: String
    let symbol: String
    let selected: Bool
    let id: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 12))
                : AnyLayout(VStackLayout(spacing: 6))
            layout {
                Image(systemName: symbol).font(.body.weight(.medium)).frame(height: 22).accessibilityHidden(true)
                Text(title).font(.caption.weight(.medium))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.8)
                if typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            }
            .foregroundStyle(ODPalette.text)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(ODPalette.text.opacity(0.35), lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(ODPressButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("sidebar.\(id)")
    }
}

@MainActor
private struct ODSidebarRecents: View {
    @EnvironmentObject private var store: ODStore
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recents").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Button {
                    store.conversationsPresented = false
                    store.selectedTab = .home
                } label: {
                    HStack(spacing: 4) {
                        Text("All chats")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .frame(minHeight: ODLayout.minimumHit).contentShape(Rectangle())
                }
                .buttonStyle(ODPressButtonStyle())
                .accessibilityLabel("All chats")
                .accessibilityIdentifier("sidebar.home")
            }
            // A new chat is not in Recents until it is saved; keep a way back to it.
            if store.hasOpenChat,
               !store.recentConversations.contains(where: { $0.id == store.selectedConversationID }) {
                Button {
                    store.conversationsPresented = false
                    store.selectedTab = .chat
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New chat").font(.body).lineLimit(1)
                        Text("Current chat").font(.subheadline).foregroundStyle(ODPalette.secondary)
                    }
                    .foregroundStyle(ODPalette.text)
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .background(store.selectedTab == .chat ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(ODPressButtonStyle())
                .accessibilityAddTraits(store.selectedTab == .chat ? .isSelected : [])
                .accessibilityIdentifier("sidebar.chat")
                .padding(.horizontal, ODLayout.conversationRowInset)
            }
            ODConversationListing(query: "", sidebar: true)
        }
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
            ODIconButton("magnifyingglass", label: "Search conversations") {
                store.conversationsPresented = false
                store.selectedTab = .home
                store.chatSearchRequested = true
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button {
                store.conversationsPresented = false
                store.selectedTab = .chat
                store.send(.newConversation)
            } label: {
                Label("New chat", systemImage: "square.and.pencil").font(.body.weight(.semibold)).lineLimit(1)
            }
            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).controlSize(.large)
            .odInkProminent()
            .disabled(!store.canPerformActions || store.isResponding)
            .accessibilityLabel("New chat").accessibilityIdentifier("sidebar.newChat")
        }
        // The reference sets the foot controls further in than the header.
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}
