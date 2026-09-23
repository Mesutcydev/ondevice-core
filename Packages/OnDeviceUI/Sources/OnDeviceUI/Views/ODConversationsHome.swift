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
            .navigationBarTitleDisplayMode(.large)
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
                        Button("Manage conversations", systemImage: "bubble.left.and.bubble.right") { store.send(.showHistory) }
                            .disabled(!store.capabilities.canShowHistory)
                        Button("Settings", systemImage: "gearshape") { store.secondaryRoute = .settings }
                    } label: { Image(systemName: "ellipsis") }
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

    var body: some View {
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
                    Button { pinnedExpanded.toggle() } label: {
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

    var body: some View {
        Button {
            store.conversationsPresented = false
            let resumeCurrent = store.hasOpenChat && store.selectedConversationID == conversation.id
            store.selectedTab = .chat
            if !resumeCurrent { store.send(.openConversation(conversation.id)) }
        } label: {
            HStack(spacing: 12) {
                if sidebar && conversation.isPinned {
                    Image(systemName: "bubble.left").font(.body).accessibilityHidden(true)
                }
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
            .foregroundStyle(ODPalette.text).padding(.vertical, 12).frame(minHeight: 68)
            .overlay(alignment: .bottom) { ODHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(!store.canPerformActions || (store.isResponding && store.selectedConversationID != conversation.id))
        .accessibilityIdentifier("\(sidebar ? "sidebar" : "home").conversation.\(conversation.id)")
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
}
