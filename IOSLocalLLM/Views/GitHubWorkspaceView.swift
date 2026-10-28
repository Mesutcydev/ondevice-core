import SwiftUI
import OnDeviceUI
import CryptoKit

/// Settings follows the same cards, semantic type and quiet controls as API providers.
struct GitHubSettingsView: View {
    @ObservedObject var connection: GitHubConnectionStore = .shared
    var client: GitHubClient = .shared
    @State private var showSignIn = false
    @State private var showToken = false
    @State private var disconnect = false
    @State private var error: String?

    var body: some View {
        List {
            ODSettingsSection(title: "Repository tools",
                              footer: "Off by default. Choose a repository in chat to give the agent access to its files. Local models stay local; API models receive the repository excerpts used in that conversation.") {
                HStack(spacing: 12) {
                    GitHubRow(title: "GitHub tools", subtitle: "Read files and prepare changes", symbol: "arrow.triangle.branch")
                    Toggle("GitHub tools", isOn: Binding(get: { connection.isEnabled }, set: { connection.setEnabled($0) }))
                        .labelsHidden().fixedSize().tint(ODPalette.text)
                        .accessibilityIdentifier("github.tools.enabled")
                }
                .padding(ODLayout.settingsPageInset)
            }
            ODSettingsSection(title: "GitHub connection",
                              footer: "Credentials stay in device-only Keychain. TokenAI never includes them in model requests, logs, or exports.") {
                if let account = connection.account {
                    GitHubRow(title: account.login, subtitle: "Connected to GitHub", symbol: "person.crop.circle")
                        .padding(ODLayout.settingsPageInset).accessibilityIdentifier("github.account")
                    GitHubRule()
                    GitHubActionRow(title: "Disconnect GitHub", symbol: "rectangle.portrait.and.arrow.right", role: .destructive) { disconnect = true }
                        .accessibilityIdentifier("github.disconnect")
                } else {
                    GitHubActionRow(title: "Sign in to GitHub", symbol: "person.crop.circle") { showSignIn = true }
                        .accessibilityIdentifier("github.signIn")
                    GitHubRule()
                    GitHubActionRow(title: "Use an access token", symbol: "key") { showToken = true }
                        .accessibilityIdentifier("github.useToken")
                }
            }
            ODSettingsSection(title: "How access works") {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Only the repository and branch selected in this chat", systemImage: "folder")
                    Label("Edits stay in a draft until you review and commit", systemImage: "doc.badge.gearshape")
                    Label("Branch creation, pull requests, and reverts require review", systemImage: "checkmark.shield")
                }.font(.subheadline).fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
            }
            if let error { GitHubErrorSection(message: error) }
        }
        .navigationTitle("GitHub & tools").navigationBarTitleDisplayMode(.inline)
        .modifier(GitHubPageStyle())
        .sheet(isPresented: $showSignIn) { GitHubSignInView(connection: connection, client: client) }
        .sheet(isPresented: $showToken) { GitHubTokenView(connection: connection, client: client) }
        .confirmationDialog("Disconnect GitHub?", isPresented: $disconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                do { try connection.disconnect(); error = nil }
                catch { self.error = GitHubError.safeMessage(error) }
            }
        } message: { Text("This deletes the saved token and turns off GitHub tools. Repository drafts remain in their chats.") }
    }
}

private struct GitHubSignInView: View {
    @StateObject private var session: GitHubSignInSession
    @ObservedObject private var connection: GitHubConnectionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    init(connection: GitHubConnectionStore, client: GitHubClient) {
        self.connection = connection
        _session = StateObject(wrappedValue: GitHubSignInSession(store: connection, client: client))
    }
    var body: some View {
        NavigationStack {
            List {
                ODSettingsSection(title: "Connect GitHub") {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Approve this device on GitHub").font(.headline)
                        Text("Sign-in requests repository access. The agent can use only the repo you select in chat, and publishing changes requires your review.")
                            .font(.subheadline).foregroundStyle(ODPalette.secondary)
                        if GitHubSignInSession.usesSiteAgentRegistration {
                            Text("GitHub's authorization page names SiteAgent, the sign-in registration shared by these apps. TokenAI stores its own token separately.")
                                .font(.footnote).foregroundStyle(ODPalette.secondary)
                        }
                        if let code = session.userCode, let url = session.verificationURL {
                            Text(code).font(.title2.monospaced().weight(.semibold)).textSelection(.enabled)
                                .accessibilityIdentifier("github.deviceCode")
                            Button("Copy code and open GitHub") {
                                UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: code]],
                                    options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(300)])
                                session.allowSafariSignInInBackground()
                                openURL(url)
                            }.buttonStyle(.borderedProminent).tint(ODPalette.text).foregroundStyle(ODPalette.background)
                            Label("Waiting for GitHub approval", systemImage: "clock").font(.footnote).foregroundStyle(ODPalette.secondary)
                        } else if session.isWorking { ProgressView("Preparing sign-in…") }
                        else { Button("Get a new sign-in code") { session.start() } }
                    }.fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
                }
                if let error = session.error { GitHubErrorSection(message: error) }
            }
            .navigationTitle("GitHub sign-in").navigationBarTitleDisplayMode(.inline)
            .modifier(GitHubPageStyle())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { session.start() }
        .onDisappear { session.cancel() }
        .onChange(of: connection.account?.id) { _, id in if id != nil { dismiss() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { session.resumePolling() } }
    }
}

private struct GitHubTokenView: View {
    @ObservedObject var connection: GitHubConnectionStore
    let client: GitHubClient
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                ODSettingsSection(title: "Fine-grained access token",
                                  footer: "Select only the repos you want to use. Enable Contents read/write, Pull requests read/write, and Checks read for all tools. Read-only tokens can browse and audit files.") {
                    SecureField("GitHub access token", text: $token)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(ODLayout.settingsPageInset).accessibilityIdentifier("github.token")
                    GitHubRule()
                    Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                        .font(.subheadline).padding(ODLayout.settingsPageInset)
                }
                if let error { GitHubErrorSection(message: error) }
                if saving { Section { ProgressView("Verifying GitHub connection…") } }
            }
            .navigationTitle("Access token").navigationBarTitleDisplayMode(.inline)
            .modifier(GitHubPageStyle())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); token = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        saving = true; error = nil
                        let credential = token; token = ""
                        task = Task {
                            do { try await connection.connect(token: credential, client: client); dismiss() }
                            catch { if !Task.isCancelled { self.error = GitHubError.safeMessage(error) } }
                            saving = false
                        }
                    }.disabled(saving || token.isEmpty).accessibilityIdentifier("github.token.connect")
                }
            }
        }.onDisappear { task?.cancel(); token = "" }
    }
}

struct GitHubRepositoryPicker: View {
    @ObservedObject var workspace: GitHubWorkspaceService
    @ObservedObject private var connection: GitHubConnectionStore
    @Environment(\.dismiss) private var dismiss
    @State private var repositories: [GitHubRepository] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var search = ""
    @State private var loading = false
    @State private var error: String?
    @State private var discard = false

    init(workspace: GitHubWorkspaceService) { self.workspace = workspace; connection = workspace.connection }

    var body: some View {
        List {
            if !connection.isEnabled || connection.account == nil {
                Section {
                    Text(connection.isEnabled ? "Connect GitHub to choose a repository." : "GitHub tools are off.")
                        .foregroundStyle(ODPalette.secondary)
                    NavigationLink("GitHub settings") { GitHubSettingsView(connection: connection, client: workspace.client) }
                }
            } else {
                if let draft = workspace.draft {
                    Section("This chat") {
                        GitHubRow(title: draft.selection.fullName, subtitle: draft.selection.branch, symbol: "arrow.triangle.branch")
                        if !workspace.isAvailable {
                            Button("Use this repository with \(connection.account?.login ?? "GitHub")") {
                                Task {
                                    let message = await workspace.reconnectRepository()
                                    if message.hasPrefix("Error:") { error = message }
                                }
                            }.disabled(workspace.isRunning).accessibilityIdentifier("github.repo.reconnect")
                        }
                        if !draft.changes.isEmpty {
                            Text("\(draft.changes.count) staged \(draft.changes.count == 1 ? "file" : "files"). Review or discard the draft before switching repositories.")
                                .font(.footnote).foregroundStyle(ODPalette.secondary)
                            Button("Discard staged changes", role: .destructive) { discard = true }
                                .accessibilityIdentifier("github.draft.discard")
                        }
                        Button("Remove repository from chat") {
                            do { try workspace.select(nil); dismiss() }
                            catch { self.error = GitHubError.safeMessage(error) }
                        }.disabled(!draft.changes.isEmpty || workspace.isRunning)
                    }
                }
                Section {
                    NavigationLink {
                        GitHubRepositoryEntryView(workspace: workspace) { dismiss() }
                    } label: {
                        GitHubRow(title: "Enter a repository", subtitle: "Owner and repository name", symbol: "link")
                    }.disabled(workspace.draft?.changes.isEmpty == false || workspace.isRunning)
                        .accessibilityIdentifier("github.repo.enter")
                    ForEach(repositories.filter { search.isEmpty || $0.fullName.localizedCaseInsensitiveContains(search) }) { repository in
                        NavigationLink {
                            GitHubBranchPicker(workspace: workspace, repository: repository) { dismiss() }
                        } label: {
                            GitHubRow(title: repository.name, subtitle: repository.owner.login,
                                      symbol: repository.isPrivate ? "lock" : "folder")
                        }
                        .disabled(workspace.draft?.changes.isEmpty == false || workspace.isRunning)
                        .accessibilityIdentifier("github.repo.\(repository.fullName)")
                    }
                    if loading { ProgressView("Loading repositories…") }
                    else if hasMore { Button(repositories.isEmpty ? "Load repositories" : "Load more repositories") { Task { await load() } } }
                    else if repositories.isEmpty { Text("No accessible repositories. Check the token's repository access.").foregroundStyle(ODPalette.secondary) }
                } header: { Text("Repositories") } footer: {
                    Text("Selecting a repository enables file reads for this chat. Repository excerpts are sent to your selected chat model. Every write requires review.")
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(ODPalette.secondary) } }
        }
        .navigationTitle("Repository").navigationBarTitleDisplayMode(.inline)
        .tint(ODPalette.text)
        .searchable(text: $search, prompt: "Find a repository")
        .task(id: connection.revision) { repositories = []; page = 1; hasMore = true; await load() }
        .confirmationDialog("Discard staged changes?", isPresented: $discard, titleVisibility: .visible) {
            Button("Discard draft", role: .destructive) { workspace.discardChanges() }
        } message: { Text("The files on GitHub will stay unchanged.") }
    }
    private func load() async {
        guard connection.isEnabled, let account = connection.account, !loading else { return }
        loading = true; error = nil
        let scope = connection.revision
        do {
            let result = try await workspace.client.repositories(token: connection.credential(for: account.id), page: page)
            try Task.checkCancellation()
            guard scope == connection.revision else { loading = false; return }
            var seen = Set(repositories.map(\.id))
            repositories += result.filter { seen.insert($0.id).inserted }
            page += 1; hasMore = result.count == 100 && page <= 20
        } catch { if !Task.isCancelled { self.error = GitHubError.safeMessage(error) } }
        loading = false
    }
}

private struct GitHubRepositoryEntryView: View {
    @ObservedObject var workspace: GitHubWorkspaceService
    let onSelected: () -> Void
    @State private var fullName = ""
    @State private var repository: GitHubRepository?
    @State private var error: String?
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                TextField("owner/repository", text: $fullName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("github.repo.name")
                Button("Find repository") {
                    loading = true; error = nil; repository = nil
                    task = Task {
                        do {
                            let parts = fullName.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "/")
                            guard parts.count == 2, let account = workspace.connection.account else { throw GitHubError.invalidRepository }
                            let scope = workspace.connection.revision
                            let value = try await workspace.client.repository(owner: parts[0], name: parts[1], token: workspace.connection.credential(for: account.id))
                            try Task.checkCancellation()
                            guard scope == workspace.connection.revision, workspace.connection.isEnabled else { throw GitHubError.cancelled }
                            repository = value
                        } catch { if !Task.isCancelled { self.error = GitHubError.safeMessage(error) } }
                        loading = false
                    }
                }.disabled(loading || fullName.isEmpty || !workspace.connection.isEnabled)
                if loading { ProgressView("Finding repository…") }
            } footer: { Text("The connected account must have access. Enter a GitHub.com repository, then choose its branch.") }
            if let repository {
                Section {
                    NavigationLink {
                        GitHubBranchPicker(workspace: workspace, repository: repository, onSelected: onSelected)
                    } label: { GitHubRow(title: repository.fullName, subtitle: "Choose a branch", symbol: "folder") }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(ODPalette.secondary) } }
        }.navigationTitle("Add repository").navigationBarTitleDisplayMode(.inline).tint(ODPalette.text)
            .onDisappear { task?.cancel() }
    }
}

private struct GitHubBranchPicker: View {
    @ObservedObject var workspace: GitHubWorkspaceService
    let repository: GitHubRepository
    let onSelected: () -> Void
    @State private var branches: [GitHubBranch] = []
    @State private var page = 1
    @State private var hasMore = true
    @State private var loading = false
    @State private var search = ""
    @State private var error: String?

    var body: some View {
        List {
            Section {
                ForEach(branches.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { branch in
                    Button {
                        do {
                            guard let account = workspace.connection.account else { throw GitHubError.disconnected }
                            try workspace.select(.init(accountID: account.id, owner: repository.owner.login, name: repository.name, branch: branch.name))
                            onSelected()
                        } catch { self.error = GitHubError.safeMessage(error) }
                    } label: {
                        HStack {
                            GitHubRow(title: branch.name, subtitle: branch.name == repository.defaultBranch ? "Default branch" : nil, symbol: "arrow.triangle.branch")
                            if workspace.draft?.selection.fullName == repository.fullName, workspace.draft?.selection.branch == branch.name {
                                Image(systemName: "checkmark").foregroundStyle(ODPalette.secondary)
                            }
                        }
                    }.foregroundStyle(ODPalette.text).accessibilityIdentifier("github.branch.\(branch.name)")
                }
                if loading { ProgressView("Loading branches…") }
                else if hasMore { Button("Load more branches") { Task { await load() } } }
            } header: { Text(repository.fullName) }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(ODPalette.secondary) } }
        }
        .navigationTitle("Branch").navigationBarTitleDisplayMode(.inline)
        .tint(ODPalette.text)
        .searchable(text: $search, prompt: "Find a branch")
        .task { await load() }
    }
    private func load() async {
        guard !loading, let account = workspace.connection.account else { return }
        loading = true
        let scope = workspace.connection.revision
        do {
            let selection = GitHubRepositorySelection(accountID: account.id, owner: repository.owner.login, name: repository.name, branch: repository.defaultBranch)
            let result = try await workspace.client.branches(selection, token: workspace.connection.credential(for: account.id), page: page)
            try Task.checkCancellation()
            guard scope == workspace.connection.revision else { loading = false; return }
            var seen = Set(branches.map(\.name))
            branches += result.filter { seen.insert($0.name).inserted }
            page += 1; hasMore = result.count == 100 && page <= 20
        } catch { if !Task.isCancelled { self.error = GitHubError.safeMessage(error) } }
        loading = false
    }
}

/// Quiet context row below the navigation title. The model pill remains at the top.
struct GitHubRepositoryIndicator: View {
    let selection: GitHubRepositorySelection?
    let changes: Int
    let isAvailable: Bool
    let onSelect: () -> Void
    let onReview: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                    Text(selection.map { "\($0.name) · \($0.branch)" } ?? "Choose repository")
                        .lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2).accessibilityHidden(true)
                }
            }.buttonStyle(.plain).accessibilityIdentifier("chat.repositoryPicker")
                .accessibilityLabel("Choose GitHub repository").accessibilityValue(selection?.label ?? "No repository selected")
            Spacer(minLength: 0)
            if changes > 0 {
                Button("\(changes) \(changes == 1 ? "change" : "changes")", action: onReview).buttonStyle(.plain)
                    .disabled(!isAvailable).accessibilityIdentifier("chat.repositoryReview")
            } else if selection != nil, !isAvailable { Text("Reconnect").font(.caption2) }
        }
        .font(.caption).foregroundStyle(ODPalette.secondary)
        .frame(minHeight: 44).padding(.horizontal, ODLayout.pageInset)
        .accessibilityElement(children: .contain)
    }
}

struct GitHubReviewView: View {
    @ObservedObject var workspace: GitHubWorkspaceService
    let plan: GitHubReviewPlan
    let onFinished: (String, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var finished = false
    @State private var includedPaths: Set<String>?

    private var selectedPaths: Set<String> { includedPaths ?? plan.includedPaths ?? Set(plan.draft.changes.map(\.path)) }
    private var isCommit: Bool { if case .commit = plan.action { return true }; return false }

    var body: some View {
        NavigationStack {
            List {
                Section("Destination") {
                    GitHubRow(title: plan.draft.selection.fullName, subtitle: plan.draft.selection.branch, symbol: "arrow.triangle.branch")
                    LabeledContent("Based on commit", value: String(plan.expectedSHA.prefix(12))).font(.caption)
                }
                GitHubReviewActionSection(plan: plan)
                if !plan.draft.changes.isEmpty {
                    Section("\(plan.draft.changes.count) \(plan.draft.changes.count == 1 ? "file" : "files")") {
                        ForEach(plan.draft.changes) { change in
                            HStack {
                                if isCommit {
                                    Toggle("Include \(change.path)", isOn: Binding(get: { selectedPaths.contains(change.path) }, set: { include in
                                        var paths = selectedPaths
                                        if include { paths.insert(change.path) } else { paths.remove(change.path) }
                                        includedPaths = paths
                                    })).labelsHidden().toggleStyle(.checkboxForReview)
                                        .accessibilityLabel("Include \(change.path)")
                                        .accessibilityIdentifier("github.review.include.\(change.path)")
                                }
                                NavigationLink { GitHubFileReview(change: change) } label: {
                                    GitHubRow(title: change.path, subtitle: change.kind, symbol: "doc.text")
                                }.accessibilityIdentifier("github.review.file.\(change.path)")
                            }
                        }
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(ODPalette.secondary).accessibilityIdentifier("github.review.error") } }
                Section {
                    if workspace.isRunning { ProgressView("Applying reviewed action…") }
                    else {
                        Button(plan.action.title) {
                            Task {
                                var approved = plan
                                if isCommit { approved.includedPaths = selectedPaths }
                                let result = await workspace.approve(approved)
                                if result.hasPrefix("Error:") { error = result; return }
                                guard !Task.isCancelled else { return }
                                finished = true; onFinished(result, true); dismiss()
                            }
                        }.disabled(!workspace.isAvailable || workspace.draft != plan.draft || (isCommit && selectedPaths.isEmpty))
                            .accessibilityIdentifier("github.review.approve")
                    }
                } footer: { Text("This publishes the exact action shown above to GitHub. Branch changes invalidate the review. Protected branches and token permissions still apply.") }
            }
            .navigationTitle("Review changes").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    workspace.cancel(); finished = true
                    onFinished("The user declined this GitHub action. Staged edits remain a draft; nothing was approved.", false)
                    dismiss()
                }.disabled(workspace.isRunning).accessibilityIdentifier("github.review.cancel")
            } }
            .interactiveDismissDisabled(workspace.isRunning)
        }.tint(ODPalette.text)
        .onDisappear {
            if !finished { onFinished("The user cancelled GitHub review. Staged edits remain a draft.", false) }
        }
    }
}

private struct GitHubReviewActionSection: View {
    let plan: GitHubReviewPlan
    var body: some View {
        Section(plan.action.title) {
            switch plan.action {
            case .commit(let message): Text(message).textSelection(.enabled)
            case .createBranch(let name):
                LabeledContent("New branch", value: name)
                Text("The chat will use this branch after creation.").font(.footnote).foregroundStyle(ODPalette.secondary)
            case .pullRequest(let title, let base, let body):
                Text(title).font(.headline)
                LabeledContent("From", value: plan.draft.selection.branch)
                LabeledContent("Into", value: base)
                if !body.isEmpty { Text(body).textSelection(.enabled) }
            case .revert(let reason, _, let paths):
                Text(reason)
                Text("Adds a commit restoring the previous file tree. It preserves history.").font(.footnote).foregroundStyle(ODPalette.secondary)
                ForEach(paths, id: \.self) { Text($0).font(.caption.monospaced()) }
            }
        }
    }
}

private struct GitHubFileReview: View {
    let change: GitHubFileChange
    @State private var showsOriginal = false
    var body: some View {
        Group {
            if let after = change.updatedText, change.original == nil || change.originalText != nil {
                CodingFileDiffView(before: change.originalText ?? "", after: after)
            } else if change.updated == nil, let before = change.originalText {
                CodingFileDiffView(before: before, after: "")
            } else { ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("File version", selection: $showsOriginal) {
                    Text("Before").tag(true); Text("After").tag(false)
                }.pickerStyle(.segmented)
                let data = showsOriginal ? change.original : change.updated
                if let data, let text = String(data: data, encoding: .utf8), !data.contains(0) {
                    Text(text.isEmpty ? "[Empty file]" : text).font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("github.review.content")
                } else if let data {
                    Text("Binary file · \(data.count.formatted()) bytes").font(.headline)
                    Text("SHA256: " + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
                        .font(.caption.monospaced()).textSelection(.enabled)
                } else { Text(showsOriginal ? "New file" : "File will be deleted").foregroundStyle(ODPalette.secondary) }
            }.padding(ODLayout.pageInset)
            } }
        }.navigationTitle(change.path).navigationBarTitleDisplayMode(.inline)
            .background { ODPageBackground().ignoresSafeArea() }
    }
}

private struct GitHubReviewCheckbox: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(configuration.isOn ? ODPalette.text : ODPalette.secondary)
                .frame(width: 44, height: 44)
        }.buttonStyle(.plain).accessibilityLabel("Include file")
            .accessibilityValue(configuration.isOn ? "Included" : "Excluded")
    }
}
private extension ToggleStyle where Self == GitHubReviewCheckbox {
    static var checkboxForReview: GitHubReviewCheckbox { .init() }
}

private struct GitHubRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(ODPalette.text)
                .frame(width: 34, height: 34).background(ODPalette.text.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(ODPalette.text)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(ODPalette.secondary) }
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
}
private struct GitHubRule: View { var body: some View { Rectangle().fill(ODPalette.line).frame(height: 1).accessibilityHidden(true) } }
private struct GitHubActionRow: View {
    let title: String
    let symbol: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) { Label(title, systemImage: symbol).font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
            .buttonStyle(.plain).padding(.horizontal, ODLayout.settingsPageInset).padding(.vertical, 4)
    }
}
private struct GitHubErrorSection: View {
    let message: String
    var body: some View {
        ODSettingsSection(title: "Connection") {
            Text(message).font(.footnote).foregroundStyle(ODPalette.secondary).fixedSize(horizontal: false, vertical: true).padding(ODLayout.settingsPageInset)
        }
    }
}
private struct GitHubPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.listStyle(.plain).scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .foregroundStyle(ODPalette.text).tint(ODPalette.text)
    }
}
