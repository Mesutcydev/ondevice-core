import SwiftUI

/// Chats owns conversation browsing; the drawer owns workspace navigation.
@MainActor
struct ODConversationsHome: View {
    @EnvironmentObject private var store: ODStore
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                ODConversationListing(query: search, sidebar: false)
                    .padding(.horizontal, ODLayout.pageInset)
                    .padding(.bottom, ODLayout.groupGap)
            }
            .scrollDismissesKeyboard(.interactively)
            .background { ODPageBackground().ignoresSafeArea() }
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { searchFocused = false }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar { EmptyView() }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ODAppMenuButton { searchFocused = false; store.conversationsPresented = true }
                        .accessibilityIdentifier("navigation.menu")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button { store.send(.showHistory) } label: {
                                Label("Manage chats", systemImage: "square.stack")
                                Text("Delete, export, or copy")
                            }
                            .disabled(!store.capabilities.canShowHistory)
                        }
                        Section {
                            Button("Settings", systemImage: "gearshape") { store.secondaryRoute = .settings }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuOrder(.fixed)
                    .accessibilityLabel("Conversation options")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New chat", systemImage: "square.and.pencil") {
                        store.selectedTab = .chat
                        store.send(.newConversation)
                    }
                    .disabled(store.isResponding || !store.canPerformActions)
                    .accessibilityIdentifier("home.newChat")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    ODKeyboardDismissKey(focus: $searchFocused)
                    Spacer(minLength: 0)
                }
            }
            .onChange(of: store.chatSearchRequested, initial: true) { _, requested in
                if requested { searchFocused = true; store.chatSearchRequested = false }
            }
            .onChange(of: store.conversationsPresented) { _, open in if open { searchFocused = false } }
            .onChange(of: store.selectedTab) { _, destination in if destination != .home { searchFocused = false } }
        }
    }
}

/// Computed only when the query or host conversation snapshot changes.
struct ODConversationGroups: Equatable {
    var pinned: [ODRecentConversation] = []
    var recent: [ODRecentConversation] = []

    init(conversations: [ODRecentConversation] = [], query: String = "") {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for conversation in conversations {
            guard query.isEmpty || "\(conversation.title) \(conversation.subtitle)".localizedCaseInsensitiveContains(query) else { continue }
            if conversation.isPinned { pinned.append(conversation) }
            else { recent.append(conversation) }
        }
    }
}

@MainActor
struct ODConversationListing: View {
    @EnvironmentObject private var store: ODStore
    let query: String
    let sidebar: Bool
    @State private var groups = ODConversationGroups()
    @State private var pinnedExpanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if sidebar { sidebarBody } else { homeBody }
    }

    /// Drawer: one flat Recents list, pinned first, like the reference chat apps.
    private var sidebarBody: some View {
        LazyVStack(alignment: .leading, spacing: 2) {
            if groups.pinned.isEmpty && groups.recent.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "clock").font(.body).foregroundStyle(ODPalette.secondary)
                        .padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No recent chats").font(.body)
                        Text("Start a new conversation").font(.subheadline).foregroundStyle(ODPalette.secondary)
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
            ForEach(groups.pinned + groups.recent) { conversation in
                ODConversationNavigationRow(conversation: conversation, sidebar: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ODLayout.conversationRowInset)
        .onChange(of: store.recentConversations, initial: true) { _, conversations in
            groups = ODConversationGroups(conversations: conversations, query: query)
        }
    }

    private var homeBody: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if groups.pinned.isEmpty && groups.recent.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your conversations").font(.headline)
                        Text("Start a chat to keep your ideas here.").font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 20)
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            if !groups.pinned.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(ODMotion.resolve(ODMotion.standard, reduceMotion: reduceMotion)) { pinnedExpanded.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Pinned").font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(pinnedExpanded ? 0 : -90))
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(sidebar ? "sidebar.pinned" : "home.pinned")
                    .accessibilityValue(pinnedExpanded ? "Expanded" : "Collapsed")
                    if pinnedExpanded {
                        ForEach(groups.pinned) { conversation in
                            ODConversationNavigationRow(conversation: conversation, sidebar: sidebar)
                        }
                    }
                }
            }
            if !groups.recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recents").font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading).accessibilityAddTraits(.isHeader)
                    ForEach(groups.recent) { conversation in
                        ODConversationNavigationRow(conversation: conversation, sidebar: sidebar)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, ODLayout.elementGap).padding(.bottom, ODLayout.pageInset)
        // Only pin changes animate; streaming subtitle updates must not.
        .animation(ODMotion.resolve(ODMotion.standard, reduceMotion: reduceMotion), value: groups.pinned.map(\.id))
        .onChange(of: store.recentConversations, initial: true) { _, conversations in
            groups = ODConversationGroups(conversations: conversations, query: query)
        }
        .onChange(of: query) { _, value in
            groups = ODConversationGroups(conversations: store.recentConversations, query: value)
            if !value.isEmpty { pinnedExpanded = true }
        }
    }
}

@MainActor
struct ODConversationNavigationRow: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dynamicTypeSize) private var typeSize
    let conversation: ODRecentConversation
    let sidebar: Bool

    private var isOpen: Bool { store.selectedTab == .chat && store.selectedConversationID == conversation.id }

    var body: some View {
        Button {
            store.conversationsPresented = false
            let resumeCurrent = store.hasOpenChat && store.selectedConversationID == conversation.id
            store.selectedTab = .chat
            if !resumeCurrent { store.send(.openConversation(conversation.id)) }
        } label: {
            if sidebar { sidebarLabel } else { homeLabel }
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(!store.canPerformActions || (store.isResponding && store.selectedConversationID != conversation.id))
        .accessibilityIdentifier("\(sidebar ? "sidebar" : "home").conversation.\(conversation.id)")
        .accessibilityAddTraits(sidebar && isOpen ? .isSelected : [])
        .accessibilityHint("Open conversation. More actions are available.")
        .contextMenu {
            if store.capabilities.canPinConversations {
                Button(conversation.isPinned ? "Unpin conversation" : "Pin conversation",
                       systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                    store.send(.setConversationPinned(conversation.id, !conversation.isPinned))
                }
            }
        }
        .accessibilityActions {
            if store.capabilities.canPinConversations {
                Button(conversation.isPinned ? "Unpin conversation" : "Pin conversation") {
                    store.send(.setConversationPinned(conversation.id, !conversation.isPinned))
                }
            }
        }
    }

    private var sidebarLabel: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if conversation.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(ODPalette.secondary)
                            .accessibilityLabel("Pinned")
                    }
                    Text(conversation.title).font(.body)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                if !conversation.subtitle.isEmpty {
                    Text(conversation.subtitle).font(.subheadline).foregroundStyle(ODPalette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.isResponding && store.selectedConversationID == conversation.id {
                ProgressView().controlSize(.small).accessibilityLabel("Responding")
            }
        }
        .foregroundStyle(ODPalette.text)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(isOpen ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }

    private var homeLabel: some View {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: ODLayout.smallGap) {
                    let titleLayout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
                    titleLayout {
                        Text(conversation.title).font(.body.weight(.semibold))
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !conversation.dateLabel.isEmpty {
                            Text(conversation.dateLabel).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                        }
                    }
                    if !conversation.subtitle.isEmpty {
                        Text(conversation.subtitle).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if store.isResponding && store.selectedConversationID == conversation.id {
                    ProgressView().accessibilityLabel("Responding")
                }
            }
            .foregroundStyle(ODPalette.text)
            .padding(.horizontal, ODLayout.conversationRowInset)
            .padding(.vertical, 12).frame(minHeight: 68)
            .overlay(alignment: .bottom) { ODHairline() }
            .contentShape(Rectangle())
    }
}
