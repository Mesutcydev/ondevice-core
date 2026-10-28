import SwiftUI
import OnDeviceUI

/// Host-owned documents and GitHub operations inside the shared workspace shell.
struct CodingWorkspaceView: View {
    @ObservedObject private var workspace: GitHubWorkspaceService
    @StateObject private var controller: CodingWorkspaceController
    let onOpenMenu: () -> Void
    let onAsk: (String) -> Void
    var contextLimit: () -> Int
    @Environment(\.odSidebarPinned) private var sidebarPinned
    @Environment(\.odWorkspaceVisible) private var visible
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var sheet: Sheet?
    @State private var review: GitHubReviewPlan?
    @State private var showPreview = false
    @State private var lastPreviewPath: String?
    @State private var newPath = ""
    @State private var commitMessage = ""
    @State private var symbolQuery = ""
    @State private var exportURL: URL?
    @FocusState private var questionFocused: Bool

    private enum Sheet: String, Identifiable {
        case repository, files, outline, reading, checkpoints, newFile, commit, preview, conflicts
        var id: String { rawValue }
    }
    private var activationKey: String? {
        guard visible, scenePhase == .active else { return nil }
        return workspace.draft.map { CodingWorkspaceText.scopeKey($0) } ?? "unselected"
    }
    private var previewTarget: String? {
        let supported = ["html", "htm", "md", "markdown"]
        if let file = controller.activeFile, supported.contains(file.language) { return file.path }
        if let last = controller.state.files.first(where: { $0.path == lastPreviewPath && supported.contains($0.language) }) { return last.path }
        return controller.state.files.first(where: { supported.contains($0.language) })?.path ?? controller.state.activePath
    }

    init(workspace: GitHubWorkspaceService, controller: CodingWorkspaceController? = nil,
         onOpenMenu: @escaping () -> Void,
         onAsk: @escaping (String) -> Void,
         contextLimit: @escaping () -> Int = { CodingWorkspaceLimits.contextCharacters }) {
        self.workspace = workspace; self.onOpenMenu = onOpenMenu; self.onAsk = onAsk
        self.contextLimit = contextLimit
        _controller = StateObject(wrappedValue: controller ?? CodingWorkspaceController(workspace: workspace))
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850 && !typeSize.isAccessibilitySize
            VStack(spacing: 0) {
                header(wide: wide)
                Divider()
                if workspace.draft == nil {
                    ContentUnavailableView {
                        Label("A workspace for your code", systemImage: "chevron.left.forwardslash.chevron.right")
                    } description: {
                        Text("Choose a GitHub repository to read source, edit files, and prepare changes with your assistant.")
                    } actions: {
                        Button("Choose repository") { sheet = .repository }.buttonStyle(.bordered)
                            .accessibilityIdentifier("coding.connect")
                    }
                } else {
                    status
                    HStack(spacing: 0) {
                        if wide {
                            CodingFileBrowser(controller: controller).frame(width: 245)
                            Divider()
                        }
                        editor(wide: wide)
                        if wide && showPreview, let path = previewTarget {
                            Divider()
                            CodingWorkspacePreview(files: controller.state.files, activePath: path)
                                .frame(width: max(280, (geometry.size.width - 245) * 0.43))
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ODWorkspaceBottomBar {
                    if workspace.draft != nil { contextComposer }
                }
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .foregroundStyle(ODPalette.text).tint(ODPalette.text)
            .sheet(item: $sheet) { destination in sheetContent(destination) }
            .sheet(item: $review) { plan in
                GitHubReviewView(workspace: workspace, plan: plan) { result, approved in
                    controller.notice = result
                    if approved { Task { await controller.synchronizeDraft() } }
                }
            }
        }
        .task(id: activationKey) {
            guard activationKey != nil else { return }
            await controller.activate(); await controller.synchronizeDraft()
        }
        .onChange(of: workspace.draft?.revision) { _, _ in
            guard visible else { return }
            Task { await controller.synchronizeDraft() }
        }
        .onChange(of: controller.conflicts) { _, paths in
            if !paths.isEmpty && visible { sheet = .conflicts }
        }
        .onChange(of: controller.state.activePath) { _, _ in
            if let file = controller.activeFile, ["html", "htm", "md", "markdown"].contains(file.language) { lastPreviewPath = file.path }
        }
        .onChange(of: visible) { _, shown in
            if !shown { questionFocused = false; controller.cancel(); Task { await controller.flush() } }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controller.cancel(); Task { await controller.flush() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .onDeviceDataWiped)) { _ in
            sheet = nil; review = nil; exportURL = nil
            Task { await controller.wipe() }
        }
        .onDisappear { controller.cancel(); Task { await controller.flush() } }
    }

    private func header(wide: Bool) -> some View {
        HStack(spacing: ODLayout.elementGap) {
            if !sidebarPinned { ODAppMenuButton(action: onOpenMenu).frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit) }
            Button { sheet = .repository } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Code").font(.headline)
                    if let selection = workspace.draft?.selection {
                        Text(selection.fullName + " · " + selection.branch)
                            .font(.caption).foregroundStyle(ODPalette.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("coding.repository")
            if workspace.draft != nil {
                if !wide {
                    icon("Files", symbol: "folder", id: "files") { sheet = .files }
                }
                Menu {
                    Button("New file", systemImage: "doc.badge.plus") { newPath = controller.folder.isEmpty ? "" : controller.folder + "/"; sheet = .newFile }
                    Button("Find symbol", systemImage: "list.bullet.indent") { sheet = .outline }.disabled(controller.activeFile == nil)
                    Button("Reading guide", systemImage: "book") { sheet = .reading }
                    Button("Save checkpoint", systemImage: "clock.badge.checkmark") { Task { await controller.checkpoint() } }
                    Button("Checkpoints", systemImage: "clock.arrow.circlepath") { sheet = .checkpoints }
                    Toggle("Save open files offline", isOn: Binding(get: { controller.state.offlineEnabled }, set: { controller.setOffline($0) }))
                    Button("Refresh file list", systemImage: "arrow.clockwise") { Task { await controller.refresh() } }
                    Button("Update from branch", systemImage: "arrow.triangle.branch") {
                        Task { await controller.resolveConflicts(); if !controller.conflicts.isEmpty { sheet = .conflicts } }
                    }
                    Divider()
                    Button("Export open files as ZIP", systemImage: "square.and.arrow.up") { export() }.disabled(controller.state.files.isEmpty)
                    Button("Export current file", systemImage: "doc") { export(singleFile: true) }.disabled(controller.activeFile == nil)
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                }.accessibilityLabel("Workspace actions").accessibilityIdentifier("coding.actions")
            }
        }.padding(.horizontal, ODLayout.pageInset).padding(.vertical, 4)
    }

    @ViewBuilder private var status: some View {
        if let message = controller.error ?? controller.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: controller.error == nil ? "info.circle" : "exclamationmark.circle").accessibilityHidden(true)
                Text(message).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                Button {
                    controller.error = nil; controller.notice = nil
                } label: { Image(systemName: "xmark").frame(minWidth: 32, minHeight: 32) }.accessibilityLabel("Dismiss workspace message")
            }.foregroundStyle(ODPalette.secondary).padding(.horizontal, ODLayout.pageInset).padding(.vertical, 6)
                .background(ODPalette.surface).accessibilityIdentifier("coding.status")
        }
        if controller.isBusy {
            HStack { ProgressView(); Text("Working…").font(.caption); Spacer(); Button("Stop") { controller.cancel() } }
                .padding(.horizontal, ODLayout.pageInset).padding(.vertical, 8)
        }
    }

    private func editor(wide: Bool) -> some View {
        VStack(spacing: 0) {
            if let file = controller.activeFile {
                fileTabs
                Divider()
                HStack(spacing: 4) {
                    Text("Ln \(file.selectedLines.lowerBound)").font(.caption.monospacedDigit())
                        .foregroundStyle(ODPalette.secondary).accessibilityIdentifier("coding.position")
                    Spacer(minLength: 0)
                    icon(controller.state.pinnedPaths.contains(file.path) ? "Remove file from context" : "Attach file to context",
                         symbol: controller.state.pinnedPaths.contains(file.path) ? "pin.fill" : "pin", id: "pin") { controller.togglePin(file.path) }
                    icon("Preview", symbol: "play.rectangle", id: "preview") {
                        questionFocused = false
                        showPreview.toggle()
                        // A sheet keeps the editor usable in narrow windows.
                        if !wide { sheet = .preview; showPreview = false }
                    }
                    Menu {
                        ForEach(CodingWorkspaceText.Action.allCases.filter { $0 != .ask }) { action in
                            Button(action.title) { ask(action) }
                        }
                        Divider()
                        Button("Bookmark this line", systemImage: "bookmark") { controller.bookmark() }
                        Button(controller.state.readPaths.contains(file.path) ? "Mark unread" : "Mark as read", systemImage: "checkmark.circle") { controller.markRead(file.path) }
                        Button("Restore unstaged edits", systemImage: "arrow.uturn.backward", role: .destructive) {
                            Task { if await controller.checkpoint() { controller.restoreActiveFile() } }
                        }.disabled(!file.hasUnstagedChanges)
                    } label: { Image(systemName: "wand.and.stars").frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit) }
                        .accessibilityLabel("Code actions").accessibilityIdentifier("coding.file.actions")
                    Button("Stage") { Task { await controller.stage() } }
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 8).frame(minHeight: ODLayout.minimumHit)
                        .disabled(controller.isBusy || workspace.isRunning || !file.hasUnstagedChanges || !workspace.isAvailable)
                        .accessibilityIdentifier("coding.stage")
                }.padding(.horizontal, ODLayout.pageInset)
                CodingCodeEditor(file: file, onEdit: controller.edit,
                                 onSelection: { controller.updateSelection($0, firstVisibleLine: $1) })
                    .id(file.path)
            } else {
                ContentUnavailableView {
                    Label("Open a source file", systemImage: "doc.text")
                } description: { Text("Browse the repository, search by file name, or start with the reading guide.") }
                actions: {
                    Button("Browse files") { sheet = .files }.buttonStyle(.bordered)
                        .accessibilityIdentifier("coding.browse")
                    Button("Start reading") { sheet = .reading }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileTabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(controller.state.files) { file in
                    HStack(spacing: 4) {
                        Button { controller.select(file.path) } label: {
                            HStack(spacing: 5) {
                                if file.hasUnstagedChanges { Circle().fill(ODPalette.text).frame(width: 5, height: 5) }
                                Text((file.path as NSString).lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                            }.frame(minHeight: 40)
                        }.accessibilityLabel(file.path + (file.hasUnstagedChanges ? ", edited" : ""))
                            .accessibilityIdentifier("coding.tab.\(file.path)")
                        Button {
                            Task {
                                if file.hasUnstagedChanges {
                                    guard await controller.checkpoint() else { return }
                                    controller.close(file.path, discardEdits: true)
                                    controller.notice = "Saved a checkpoint before closing \(file.path)."
                                } else { controller.close(file.path) }
                            }
                        } label: {
                            Image(systemName: "xmark").font(.caption2).frame(width: 32, height: 40)
                        }.accessibilityLabel("Close \(file.path)")
                    }.padding(.leading, 10)
                        .background(file.path == controller.state.activePath ? ODPalette.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                        .buttonStyle(.plain)
                }
            }.padding(.horizontal, ODLayout.pageInset).padding(.vertical, 5)
        }.scrollIndicators(.hidden)
    }

    private var contextComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !controller.state.pinnedPaths.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(controller.state.pinnedPaths, id: \.self) { path in
                            Button { controller.togglePin(path) } label: {
                                Label((path as NSString).lastPathComponent, systemImage: "xmark.circle")
                                    .font(.caption).padding(7).background(ODPalette.selected, in: Capsule())
                            }.accessibilityLabel("Remove \(path) from context")
                        }
                    }
                }.scrollIndicators(.hidden)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask about code… @file or @folder", text: $controller.question, axis: .vertical)
                    .lineLimit(1...3).font(.subheadline).focused($questionFocused)
                    .accessibilityIdentifier("coding.question")
                Button { ask(.ask) } label: {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        .frame(width: 40, height: 40).foregroundStyle(ODPalette.onSend)
                        .background(ODPalette.send, in: Circle())
                }.disabled(controller.isBusy || controller.activeFile == nil)
                    .accessibilityLabel("Ask assistant about code").accessibilityIdentifier("coding.ask")
            }.padding(10).background(ODPalette.input, in: RoundedRectangle(cornerRadius: 20))
            HStack {
                Text("Selected code or open file → current chat").font(.caption2).foregroundStyle(ODPalette.secondary)
                Spacer()
                Button("Review \(workspace.draft?.changes.count ?? 0) files") { commitMessage = ""; sheet = .commit }
                    .font(.caption.weight(.medium)).disabled(workspace.draft?.changes.isEmpty != false)
                    .accessibilityIdentifier("coding.review")
            }
            if let exportURL {
                ShareLink(item: exportURL) { Label("Share export", systemImage: "square.and.arrow.up") }
                    .font(.caption).accessibilityIdentifier("coding.export.share")
            }
        }.padding(.horizontal, ODLayout.pageInset).padding(.top, 8).padding(.bottom, 6)
    }

    @ViewBuilder private func sheetContent(_ destination: Sheet) -> some View {
        switch destination {
        case .repository: GitHubRepositoryPicker(workspace: workspace)
        case .files:
            navigationSheet("Files") { CodingFileBrowser(controller: controller, onOpen: { sheet = nil }) }
        case .outline:
            navigationSheet("Symbols") {
                List(controller.symbols.filter { symbolQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(symbolQuery) }) { symbol in
                    Button { controller.goToLine(symbol.line); sheet = nil } label: {
                        LabeledContent(symbol.title, value: "L\(symbol.line)")
                    }
                }.searchable(text: $symbolQuery, prompt: "Find symbol")
                    .overlay { if controller.symbols.isEmpty { ContentUnavailableView("No symbols found", systemImage: "list.bullet.indent") } }
            }
        case .reading:
            navigationSheet("Read repository") { CodingReadingGuide(controller: controller, onOpen: { sheet = nil }) }
        case .checkpoints:
            navigationSheet("Checkpoints") {
                List {
                    Section {
                        Button("Save current workspace", systemImage: "clock.badge.checkmark") { Task { await controller.checkpoint() } }
                    } footer: { Text("The latest five checkpoints are encrypted on this device. Restoring one first saves your current edits.") }
                    ForEach(controller.state.checkpoints) { checkpoint in
                        Button { Task { await controller.restoreCheckpoint(checkpoint); sheet = nil } } label: {
                            VStack(alignment: .leading) {
                                Text(checkpoint.title).lineLimit(2)
                                Text(checkpoint.date, style: .date).font(.caption).foregroundStyle(ODPalette.secondary)
                                Text(checkpoint.date, style: .time).font(.caption).foregroundStyle(ODPalette.secondary)
                            }
                        }.accessibilityIdentifier("coding.checkpoint.\(checkpoint.id)")
                    }
                }
            }
        case .newFile:
            navigationSheet("New file") {
                Form {
                    TextField("Relative path, e.g. Sources/Example.swift", text: $newPath).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("coding.new.path")
                    Button("Create file") { controller.createFile(newPath); sheet = nil }.disabled(newPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("coding.new.create")
                }
            }
        case .commit:
            navigationSheet("Prepare review") {
                Form {
                    Section("Commit message") {
                        TextField("Describe these changes", text: $commitMessage, axis: .vertical).lineLimit(2...5)
                            .accessibilityIdentifier("coding.commit.message")
                    }
                    Section {
                        ForEach(workspace.draft?.changes ?? []) { change in
                            NavigationLink(change.path) { CodingFileDiffView(before: change.originalText ?? "", after: change.updatedText ?? "") }
                        }
                        Button("Choose files and review") {
                            Task {
                                let result = await workspace.run(name: "request_user_approval", args: ["message": commitMessage])
                                switch result {
                                case .review(let plan): sheet = nil; review = plan
                                case .result(let message): controller.error = message; sheet = nil
                                }
                            }
                        }.disabled(workspace.isRunning || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("coding.commit.prepare")
                    } footer: { Text("Next, choose which staged files to include and review their diffs before publishing.") }
                }
            }
        case .preview:
            navigationSheet("Preview") {
                if let path = previewTarget { CodingWorkspacePreview(files: controller.state.files, activePath: path) }
            }
        case .conflicts:
            navigationSheet("Branch changes") {
                List {
                    Section {
                        ForEach(controller.conflicts, id: \.self) { path in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(path).font(.subheadline.weight(.medium))
                                Picker("Resolution for \(path)", selection: Binding<Bool?>(
                                    get: { controller.conflictChoices[path] }, set: { controller.conflictChoices[path] = $0 })) {
                                    Text("Choose…").tag(Bool?.none)
                                    Text("Keep my edit").tag(Bool?.some(true))
                                    Text("Use branch version").tag(Bool?.some(false))
                                }
                            }
                        }
                        Button("Apply choices") {
                            Task { await controller.resolveConflicts(); if controller.conflicts.isEmpty { sheet = nil } }
                        }.disabled(controller.isBusy || controller.conflicts.contains { controller.conflictChoices[$0] == nil })
                    } footer: { Text("These files changed on GitHub. Keeping your edit replaces the branch version in your draft. Review again before committing.") }
                }
            }
        }
    }

    private func navigationSheet<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().scrollContentBackground(.hidden).background(ODPalette.background)
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheet = nil } } }
        }.tint(ODPalette.text).foregroundStyle(ODPalette.text)
    }
    private func icon(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit) }
            .accessibilityLabel(title).accessibilityIdentifier("coding.\(id)")
    }
    private func ask(_ action: CodingWorkspaceText.Action) {
        questionFocused = false
        Task {
            if let prompt = await controller.makeQuestion(action: action, maximumCharacters: contextLimit()) {
                controller.question = ""; onAsk(prompt)
            }
        }
    }
    private func export(singleFile: Bool = false) {
        do {
            let file = singleFile ? controller.activeFile : nil
            let data = try file.map { Data($0.text.utf8) } ?? CodingWorkspaceArchive.make(files: controller.state.files)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodingExports", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent(file.map { ($0.path as NSString).lastPathComponent } ?? "Workspace.zip")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            if let old = exportURL { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
            exportURL = url
            controller.notice = "Export ready. Use Share export below to save the files."
        } catch { controller.error = "The workspace could not be exported. Try closing a large file and export again." }
    }
}

private struct CodingFileBrowser: View {
    @ObservedObject var controller: CodingWorkspaceController
    var onOpen: () -> Void = {}
    @State private var query = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(ODPalette.secondary)
                TextField("Find file", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("coding.files.search")
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear file search") }
            }.padding(12).background(ODPalette.input, in: RoundedRectangle(cornerRadius: 12)).padding(ODLayout.pageInset)
            if !controller.folder.isEmpty && controller.search.isEmpty {
                Button {
                    controller.folder = (controller.folder as NSString).deletingLastPathComponent
                } label: {
                    Label(controller.folder, systemImage: "chevron.backward").font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.padding(.horizontal, ODLayout.pageInset)
            }
            List(controller.visibleEntries) { entry in
                Button {
                    if entry.isDirectory { query = ""; controller.search = ""; controller.folder = entry.path }
                    else { Task { await controller.open(entry.path); if controller.state.activePath == entry.path { onOpen() } } }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: entry.isDirectory ? "folder" : "doc.text").foregroundStyle(ODPalette.secondary)
                        Text(controller.search.isEmpty ? (entry.path as NSString).lastPathComponent : entry.path)
                            .font(.subheadline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if controller.state.readPaths.contains(entry.path) { Image(systemName: "checkmark").font(.caption).foregroundStyle(ODPalette.secondary) }
                    }.frame(minHeight: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).listRowBackground(entry.path == controller.state.activePath ? ODPalette.selected : .clear)
                    .accessibilityIdentifier("coding.file.\(entry.path)")
            }.listStyle(.plain).scrollContentBackground(.hidden)
                .overlay { if controller.visibleEntries.isEmpty && !controller.isBusy { ContentUnavailableView.search(text: controller.search) } }
        }.background(ODPalette.background)
            .onAppear { query = controller.search }
            .task(id: query) {
                do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation(); controller.search = query }
                catch { }
            }
    }
}

private struct CodingReadingGuide: View {
    @ObservedObject var controller: CodingWorkspaceController
    let onOpen: () -> Void
    var body: some View {
        List {
            Section {
                LabeledContent("Files read", value: controller.readingProgress)
                Text("Start with the README, follow the source, and ask the assistant to explain a selected range. Answers are prepared with file and line references.")
                    .font(.footnote).foregroundStyle(ODPalette.secondary)
            }
            if !controller.state.bookmarks.isEmpty {
                Section("Bookmarks") {
                    ForEach(controller.state.bookmarks) { bookmark in
                        Button {
                            Task {
                                await controller.open(bookmark.path)
                                if controller.state.activePath == bookmark.path { controller.goToLine(bookmark.line); onOpen() }
                            }
                        } label: {
                            LabeledContent(bookmark.path, value: "L\(bookmark.line)")
                        }.swipeActions { Button("Remove", role: .destructive) { controller.removeBookmark(bookmark) } }
                    }
                }
            }
            Section("Source") {
                ForEach(controller.readingEntries) { entry in
                    HStack {
                        Button { Task { await controller.open(entry.path); if controller.state.activePath == entry.path { onOpen() } } } label: {
                            Text(entry.path).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        }
                        Button { controller.markRead(entry.path) } label: {
                            Image(systemName: controller.state.readPaths.contains(entry.path) ? "checkmark.circle.fill" : "circle")
                                .frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel("Toggle read: \(entry.path)")
                    }
                }
            }
        }.listStyle(.insetGrouped)
    }
}
