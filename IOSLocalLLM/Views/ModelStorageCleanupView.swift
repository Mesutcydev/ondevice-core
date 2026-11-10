import SwiftUI

// MARK: - Guided model storage cleanup

/// Lets people decide what remains on-device in one pass. Everything starts
/// kept, including partial downloads, so nothing is removed unless it is
/// unticked, ticked, or "Active only" is chosen. Required models are locked on;
/// active models may be removed because the download center safely resets
/// their role before deleting the files.
struct ModelStorageCleanupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ObservedObject private var center = ModelDownloadCenter.shared
    @State private var items: [ModelStorageCleanupItem] = []
    @State private var keepIDs: Set<String> = []
    /// Off by default: clearing resume data restarts every paused download.
    @State private var removePartialDownloads = false
    @State private var isRemoving = false
    @State private var showRemovalConfirmation = false
    @State private var didLoad = false

    private var removableItems: [ModelStorageCleanupItem] {
        items.filter { !$0.isRequired && !keepIDs.contains($0.id) }
    }

    private var reclaimableBytes: Int64 {
        removableItems.reduce(0) { $0 + $1.estimatedBytes }
            + (removePartialDownloads ? center.orphanedDownloadBytes : 0)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                StudioPageBackground()
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ModelStorageCleanupHeader(
                            installedCount: items.count,
                            selectedCount: keepIDs.count,
                            storageUsed: center.totalStorageUsed
                                + CoreAIModelStore.shared.installations.reduce(0) { $0 + max(0, $1.manifest.totalDownloadBytes) }
                                + ClassifierModelStore.shared.storageBytes
                        )

                        if items.isEmpty {
                            ModelStorageCleanupEmptyState()
                        } else {
                            ModelStorageCleanupSelectionBar(
                                allSelected: items.allSatisfy { keepIDs.contains($0.id) },
                                onSelectAll: selectAll,
                                onKeepActiveOnly: keepActiveAndRequiredOnly
                            )

                            ForEach(items) { item in
                                ModelStorageCleanupRow(
                                    item: item,
                                    isKept: keepIDs.contains(item.id),
                                    onToggle: { toggleKeep(item) }
                                )
                            }
                        }

                        if center.orphanedDownloadBytes > 0 {
                            ModelPartialDownloadCleanupRow(
                                bytes: center.orphanedDownloadBytes,
                                isSelected: removePartialDownloads,
                                onToggle: { removePartialDownloads.toggle() }
                            )
                        }

                        // The action bar is a bottom inset; 96pt of tail on top of that
            // pushed the last row a third of a screen away from it.
            Color.clear.frame(height: StudioSpacing.xxl)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
            }
            .navigationTitle("Storage Cleanup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ModelStorageCleanupActionBar(
                    removalCount: removableItems.count,
                    reclaimableBytes: reclaimableBytes,
                    enabled: !isRemoving && (!removableItems.isEmpty
                        || (removePartialDownloads && center.orphanedDownloadBytes > 0)),
                    isBusy: isRemoving,
                    onRemove: { showRemovalConfirmation = true }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.adaptiveMaterial(reduceTransparency: reduceTransparency,
                                              opaque: T.studio.surfaceRaised))
            }
            .confirmationDialog(
                "Remove unselected models?",
                isPresented: $showRemovalConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove and free \(reclaimableBytes.formattedBytes)", role: .destructive) {
                    performCleanup()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Models marked Keep stay on this device. Removed models can be downloaded again later.")
            }
            .onAppear(perform: loadItemsIfNeeded)
        }
    }

    private func loadItemsIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        center.refreshAllStates()
        items = (center.models.filter(\.isReady).map(ModelStorageCleanupItem.init) + Self.otherInstalledItems())
            .sorted {
                if $0.isRequired != $1.isRequired { return $0.isRequired }
                if $0.isActive != $1.isActive { return $0.isActive }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        keepIDs = Set(items.map(\.id))
    }

    /// Image, Core AI and classifier models live outside the download center,
    /// each with its own store and removal path.
    @MainActor
    private static func otherInstalledItems() -> [ModelStorageCleanupItem] {
        let images = ImageGenerationService.shared
        let settings = AppSettings.shared
        let workbench = CoreAIClassifierHost.workbench
        return ImageGenerationService.catalog.filter { images.isInstalled($0) }.map { model in
            ModelStorageCleanupItem(
                id: "image:\(model.id)", displayName: model.displayName,
                detail: "\(model.sizeLabel) · \(model.id)", glyph: "wand.and.stars",
                estimatedBytes: images.installedBytes(model),
                isActive: images.selectedModelID == model.id,
                remove: { images.deleteModel(model) },
                isRemoved: { !images.isInstalled(model) })
        } + CoreAIModelStore.shared.installations.map { pack in
            ModelStorageCleanupItem(
                id: pack.assistantSelectionID, displayName: pack.manifest.displayName,
                detail: "\(pack.manifest.totalDownloadBytes.formattedBytes) · Core AI", glyph: "cpu",
                estimatedBytes: max(0, pack.manifest.totalDownloadBytes),
                isActive: settings.assistantModelID == pack.assistantSelectionID
                    || workbench.selectedModelID == pack.assistantSelectionID,
                remove: { CoreAIDownloadCenter.shared.handleDeletion(id: pack.id) },
                isRemoved: { CoreAIModelStore.shared.installedModel(id: pack.id) == nil })
        } + ClassifierCatalog.models.filter {
            ClassifierModelStore.shared.installedIDs.contains($0.selectionID)
        }.map { entry in
            let bytes = ClassifierModelStore.shared.installedSizes[entry.selectionID] ?? entry.bytes
            return ModelStorageCleanupItem(
                id: entry.selectionID, displayName: entry.name,
                detail: "\(bytes.formattedBytes) · \(entry.repo)", glyph: "checklist",
                estimatedBytes: bytes,
                isActive: workbench.selectedModelID == entry.selectionID,
                remove: { ClassifierModelStore.shared.remove(entry) },
                isRemoved: { !ClassifierModelStore.shared.installedIDs.contains(entry.selectionID) })
        }
    }

    private func selectAll() {
        keepIDs = Set(items.map(\.id))
        HapticManager.selection()
    }

    private func keepActiveAndRequiredOnly() {
        keepIDs = Set(items.filter { $0.isActive || $0.isRequired }.map(\.id))
        HapticManager.selection()
    }

    private func toggleKeep(_ item: ModelStorageCleanupItem) {
        guard !item.isRequired else { return }
        if keepIDs.contains(item.id) {
            keepIDs.remove(item.id)
        } else {
            keepIDs.insert(item.id)
        }
        HapticManager.selection()
    }

    private func performCleanup() {
        guard !isRemoving else { return }
        isRemoving = true
        let removed = removableItems
        let includePartials = removePartialDownloads
        Task { @MainActor in
            for item in removed { item.remove() }
            // Core AI packs and classifiers finish removing in the background,
            // and a model in use can be refused. Wait (bounded) so the result
            // below reports what is actually gone.
            let deadline = Date().addingTimeInterval(20)
            while removed.contains(where: { !$0.isRemoved() }) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            let gone = removed.filter { $0.isRemoved() }
            var freed = gone.reduce(Int64(0)) { $0 + $1.estimatedBytes }
            if includePartials {
                freed += center.cleanupOrphanedDownloads()
            }
            center.refreshAllStates()
            let remaining = removed.count - gone.count
            if remaining == 0 {
                HapticManager.impact(.medium)
                ToastCenter.shared.success("Storage cleaned", detail: "Freed about \(freed.formattedBytes)")
            } else {
                HapticManager.error()
                ToastCenter.shared.error("Some models were not removed",
                                         detail: "\(remaining) still on this device. Freed about \(freed.formattedBytes).")
            }
            isRemoving = false
            dismiss()
        }
    }
}

private struct ModelStorageCleanupItem: Identifiable {
    let id: String
    let displayName: String
    let detail: String
    let glyph: String
    let estimatedBytes: Int64
    let isRequired: Bool
    let isActive: Bool
    let remove: @MainActor () -> Void
    /// True once the files are gone. Some removals finish after `remove` returns.
    let isRemoved: @MainActor () -> Bool

    init(id: String, displayName: String, detail: String, glyph: String,
         estimatedBytes: Int64, isActive: Bool,
         remove: @escaping @MainActor () -> Void, isRemoved: @escaping @MainActor () -> Bool) {
        self.id = id
        self.displayName = displayName
        self.detail = detail
        self.glyph = glyph
        self.estimatedBytes = estimatedBytes
        self.isRequired = false
        self.isActive = isActive
        self.remove = remove
        self.isRemoved = isRemoved
    }

    @MainActor
    init(model: DownloadableModel) {
        id = model.id
        displayName = model.displayName
        detail = "\(model.sizeLabel) · \(model.sourceRepoID)"
        switch model.category {
        case .assistant: glyph = "brain"
        case .vlm: glyph = "eye"
        case .voice: glyph = "waveform"
        case .imageGen: glyph = "wand.and.stars"
        }
        // Measured bytes when the downloader has them; the label is a display
        // string ("~2.3 GB", "—") and only a fallback.
        estimatedBytes = model.totalBytes > 0 ? model.totalBytes : Self.parseBytes(model.sizeLabel)
        isRequired = model.isRequired
        isActive = Self.isActive(model)
        // Same entry point as a model card: it resets active selections and
        // unloads the owning service before the files go.
        remove = { ModelDownloadCenter.shared.handleDeletion(of: model) }
        isRemoved = { !model.isReady }
    }

    @MainActor
    private static func isActive(_ model: DownloadableModel) -> Bool {
        let settings = AppSettings.shared
        let assistant = LocalModelRegistry.unwrapAssistantSelectionID(settings.assistantModelID)
        let voiceAssistant = LocalModelRegistry.unwrapAssistantSelectionID(settings.voiceConversationModelID)
        let vision = LocalModelRegistry.storedVisionSelectionID(settings.cameraVisualModelID)
        let ids = Set([model.id, model.sourceRepoID])
        if ids.contains(assistant) || ids.contains(voiceAssistant) || ids.contains(vision) { return true }
        if let engine = model.supportedVoiceEngine,
           settings.voiceEngine == engine.rawValue { return true }
        return false
    }

    private static func parseBytes(_ label: String) -> Int64 {
        // Byte labels follow the device locale, where the decimal mark may be a comma.
        let normalized = label.lowercased().replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: ",", with: ".")
        let scanner = Scanner(string: normalized)
        guard let value = scanner.scanDouble() else { return 0 }
        if normalized.contains("gb") { return Int64(value * 1_000_000_000) }
        if normalized.contains("mb") { return Int64(value * 1_000_000) }
        if normalized.contains("kb") { return Int64(value * 1_000) }
        return Int64(value)
    }
}

private struct ModelStorageCleanupHeader: View {
    let installedCount: Int
    let selectedCount: Int
    let storageUsed: Int64

    @Environment(\.koduTheme) private var T

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KCaption(text: "KEEP WHAT YOU USE", color: T.accent)
            Text("Models are stored separately from the app")
                .font(T.sans(24, .semibold))
                .foregroundColor(T.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text("Everything starts selected. Untick the models you no longer need, or choose Active only to keep just the ones in use.")
                .font(T.sans(13))
                .foregroundColor(T.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Label("\(selectedCount) kept", systemImage: "checkmark.circle.fill")
                Spacer()
                Text("\(installedCount) installed · \(storageUsed.formattedBytes)")
            }
            .font(T.mono(10, .semibold))
            .foregroundColor(T.ink3)
        }
        .padding(16)
        .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface, fallbackStroke: T.rule)
    }
}

private struct ModelStorageCleanupSelectionBar: View {
    let allSelected: Bool
    let onSelectAll: () -> Void
    let onKeepActiveOnly: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        HStack(spacing: 8) {
            Text("Keep")
                .font(T.sans(13, .semibold))
                .foregroundColor(T.ink)
            Spacer()
            Button("Active only", action: onKeepActiveOnly)
            Button(allSelected ? "All selected" : "Select all", action: onSelectAll)
                .disabled(allSelected)
        }
        .font(T.sans(12, .semibold))
        .foregroundColor(T.accent)
        .padding(.horizontal, 4)
    }
}

private struct ModelStorageCleanupRow: View {
    let item: ModelStorageCleanupItem
    let isKept: Bool
    let onToggle: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: item.glyph)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(isKept ? T.accent : T.ink3)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                        .fill((isKept ? T.accent : T.ink3).opacity(0.10)))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                            .lineLimit(2)
                        if item.isActive {
                            Text("ACTIVE")
                                .font(T.mono(8, .bold))
                                .foregroundColor(T.good)
                        }
                    }
                    Text(item.detail)
                        .font(T.mono(9))
                        .foregroundColor(T.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if item.isRequired {
                    Label("Required", systemImage: "lock.fill")
                        .font(T.mono(9, .semibold))
                        .foregroundColor(T.warn)
                } else {
                    Image(systemName: isKept ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isKept ? T.accent : T.ink3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface, fallbackStroke: T.rule)
        }
        .buttonStyle(.plain)
        .disabled(item.isRequired)
        .accessibilityLabel("\(item.displayName), \(isKept ? "keep" : "remove")")
    }
}

private struct ModelPartialDownloadCleanupRow: View {
    let bytes: Int64
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.dotted")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(T.warn)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                        .fill(T.warn.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Partial downloads")
                        .font(T.sans(14, .semibold))
                        .foregroundColor(T.ink)
                    Text("Cancelled files and resumable transfer cache · \(bytes.formattedBytes). Paused downloads may restart.")
                        .font(T.mono(9))
                        .foregroundColor(T.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(isSelected ? T.warn : T.ink3)
            }
            .padding(14)
            .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface, fallbackStroke: T.rule)
        }
        .buttonStyle(.plain)
    }
}

private struct ModelStorageCleanupActionBar: View {
    let removalCount: Int
    let reclaimableBytes: Int64
    let enabled: Bool
    var isBusy = false
    let onRemove: () -> Void

    var body: some View {
        Button(action: onRemove) {
            HStack {
                if isBusy { ProgressView().tint(.white) } else { Image(systemName: "trash") }
                Text(isBusy ? "Removing…" : removalCount > 0 ? "Remove \(removalCount) models" : "Clear partial downloads")
                Spacer()
                Text(reclaimableBytes.formattedBytes)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(enabled ? Color.accentColor : Color.secondary, in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private struct ModelStorageCleanupEmptyState: View {
    var body: some View {
        ContentUnavailableView(
            "No downloaded models",
            systemImage: "externaldrive",
            description: Text("Downloaded models will appear here when there is storage to manage.")
        )
        .padding(.vertical, 36)
    }
}
