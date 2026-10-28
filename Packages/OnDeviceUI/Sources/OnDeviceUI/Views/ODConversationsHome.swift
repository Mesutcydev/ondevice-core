import SwiftUI

/// Chats owns conversation browsing; the drawer owns workspace navigation.
@MainActor
struct ODConversationsHome: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.odSidebarPinned) private var sidebarPinned
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
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search chats", bundle: .module))
            .searchFocused($searchFocused)
            .onSubmit(of: .search) { searchFocused = false }
            .odNavigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar { EmptyView() }
            }
            .toolbar {
                if !sidebarPinned {
                    ToolbarItem(placement: .topBarLeading) {
                        ODAppMenuButton { searchFocused = false; store.conversationsPresented = true }
                            .accessibilityIdentifier("navigation.menu")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Section {
                            Button { store.send(.showHistory) } label: {
                                Label(ODLocalizedString("Manage chats"), systemImage: "square.stack")
                                Text("Delete, export, or copy", bundle: .module)
                            }
                            .disabled(!store.capabilities.canShowHistory)
                        }
                        Section {
                            Button(ODLocalizedString("Settings"), systemImage: "gearshape") { store.secondaryRoute = .settings }
                        }
                    } label: { Image(systemName: "ellipsis") }
                    .menuOrder(.fixed)
                    .accessibilityLabel(Text("Conversation options", bundle: .module))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(ODLocalizedString("New chat"), systemImage: "square.and.pencil") {
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

    init(conversations: [ODRecentConversation] = [], query: String = "", transcriptMatches: Set<String> = []) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        for conversation in conversations {
            guard query.isEmpty || transcriptMatches.contains(conversation.id)
                || "\(conversation.title) \(conversation.subtitle)".localizedCaseInsensitiveContains(query) else { continue }
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
    @ScaledMetric(relativeTo: .body) private var sidebarIconWidth = ODLayout.sidebarIconColumn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if sidebar { sidebarBody } else { homeBody }
    }

    /// Drawer: one flat Recents list, pinned first, like the reference chat apps.
    private var sidebarBody: some View {
        LazyVStack(alignment: .leading, spacing: ODLayout.sidebarRowGap) {
            if groups.pinned.isEmpty && groups.recent.isEmpty {
                HStack(alignment: .top, spacing: ODLayout.labelGap) {
                    Image(systemName: "clock").font(.body).foregroundStyle(ODPalette.secondary)
                        .frame(width: sidebarIconWidth)
                        .padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: ODLayout.sidebarRowGap) {
                        Text("No recent chats", bundle: .module).font(.body)
                        Text("Start a new conversation", bundle: .module).font(.subheadline).foregroundStyle(ODPalette.secondary)
                    }
                }
                .padding(.vertical, ODLayout.elementGap)
                .padding(.horizontal, ODLayout.sidebarContentInset)
                .accessibilityElement(children: .combine)
            }
            ForEach(groups.pinned + groups.recent) { conversation in
                ODConversationNavigationRow(conversation: conversation, sidebar: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: store.recentConversations, initial: true) { _, conversations in
            groups = makeGroups(conversations, query)
        }
    }

    /// Messages are searched only while a query is active.
    private func makeGroups(_ conversations: [ODRecentConversation], _ query: String) -> ODConversationGroups {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = trimmed.isEmpty ? [] : store.transcriptMatches?(trimmed) ?? []
        return ODConversationGroups(conversations: conversations, query: trimmed, transcriptMatches: matches)
    }

    private var homeBody: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if groups.pinned.isEmpty && groups.recent.isEmpty {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Your conversations", bundle: .module).font(.headline)
                        Text("Start a chat to keep your ideas here.", bundle: .module).font(.subheadline).foregroundStyle(.secondary)
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
                            Text("Pinned", bundle: .module).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
                                .rotationEffect(.degrees(pinnedExpanded ? 0 : -90))
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(sidebar ? "sidebar.pinned" : "home.pinned")
                    .accessibilityValue(Text(odKey: pinnedExpanded ? "Expanded" : "Collapsed"))
                    if pinnedExpanded {
                        ForEach(groups.pinned) { conversation in
                            ODConversationNavigationRow(conversation: conversation, sidebar: sidebar)
                        }
                    }
                }
            }
            if !groups.recent.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recents", bundle: .module).font(.subheadline.weight(.semibold))
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
            groups = makeGroups(conversations, query)
        }
        .onChange(of: query) { _, value in
            groups = makeGroups(store.recentConversations, value)
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
        .accessibilityHint(Text("Open conversation. More actions are available.", bundle: .module))
        .contextMenu {
            if store.capabilities.canPinConversations {
                Button(ODLocalizedString(key: conversation.isPinned ? "Unpin conversation" : "Pin conversation"),
                       systemImage: conversation.isPinned ? "pin.slash" : "pin") {
                    store.send(.setConversationPinned(conversation.id, !conversation.isPinned))
                }
            }
        }
        .accessibilityActions {
            if store.capabilities.canPinConversations {
                Button(ODLocalizedString(key: conversation.isPinned ? "Unpin conversation" : "Pin conversation")) {
                    store.send(.setConversationPinned(conversation.id, !conversation.isPinned))
                }
            }
        }
    }

    private var sidebarLabel: some View {
        HStack(spacing: ODLayout.labelGap) {
            VStack(alignment: .leading, spacing: ODLayout.smallGap) {
                HStack(spacing: ODLayout.elementGap) {
                    Text(conversation.title).font(.body)
                        .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                }
                if !conversation.subtitle.isEmpty {
                    Text(conversation.subtitle).font(.subheadline).foregroundStyle(ODPalette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if conversation.isPinned {
                Image(systemName: "pin.fill").font(.caption2).foregroundStyle(ODPalette.secondary)
                    .accessibilityLabel(Text("Pinned", bundle: .module))
            }
            if store.isResponding && store.selectedConversationID == conversation.id {
                ODBrandMark(height: 9, motion: .live).foregroundStyle(ODPalette.text)
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text("Responding", bundle: .module))
            }
        }
        .foregroundStyle(ODPalette.text)
        .padding(.horizontal, ODLayout.sidebarContentInset).padding(.vertical, ODLayout.elementGap)
        .frame(minHeight: ODLayout.sidebarRowHeight)
        .background(isOpen ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            Text(odKey: conversation.dateLabel).font(.caption).foregroundStyle(.secondary)
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
                    ODBrandMark(height: 9, motion: .live).foregroundStyle(ODPalette.text)
                    .accessibilityElement(children: .ignore).accessibilityLabel(Text("Responding", bundle: .module))
                }
            }
            .foregroundStyle(ODPalette.text)
            .padding(.horizontal, ODLayout.conversationRowInset)
            .padding(.vertical, 12).frame(minHeight: 68)
            .overlay(alignment: .bottom) { ODHairline() }
            .contentShape(Rectangle())
    }
}
