import SwiftUI
import OnDeviceUI
import Combine

// MARK: - OnboardingModelPickerView
//
// Final step of the onboarding flow: ask the user to pick one assistant
// LLM and one visual VLM before they reach the main app. This avoids
// the previous "land on home tab, see a download going, wonder what's
// happening" pattern.
//
// Two-section layout matches the Choose-a-Model reference:
//   • Assistant — text-only OR multimodal both qualify. We curate 3
//     options across small/medium/large so the user can pick by
//     device class.
//   • Visual — ONLY multimodal models. Pre-filtering at the source
//     means the user CAN'T pick a text-only model in this slot (the
//     filter is structural, not a runtime warning).
//
// Each card carries a vendor thumb, capability pills, and a clear
// pick (radio). Selecting both unlocks the primary CTA which kicks
// off the downloads and dismisses onboarding.
//
// Skip leaves AppSettings on its tier-appropriate defaults — the
// home tab still works because BundledVLMInstaller pre-installs
// SmolVLM2 GGUF and the assistant picks a tier-fitting default
// via DeviceTierAdvisor.

struct OnboardingModelPickerView: View {

    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var center   = ModelDownloadCenter.shared
    @Environment(\.koduTheme) private var T

    /// Called by the parent OnboardingView when the user finishes
    /// (either via "Download & Continue" or "Skip"). The parent
    /// flips `hasSeenOnboarding` so we don't re-show the picker.
    var onComplete: () -> Void

    // MARK: - Selection state
    //
    // Default selections are seeded by `tierAwareDefaults()` on appear,
    // so a Pro/Max device starts on its tier-appropriate pick rather
    // than the safe-small fallback. The seed values below only apply
    // before `.onAppear` runs (a flash for one frame at most).

    @State private var pickedAssistantID: String = "qwen2.5-coder-1.5b"
    @State private var pickedVisualRepoID: String = "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"

    /// Onboarding splits into the model picker and a download gate. The gate
    /// blocks entry until both picks finish downloading — but with a Skip so a
    /// flaky network can never lock a first launch out of the app.
    private enum Phase { case picking, downloading }
    @State private var phase: Phase = .picking
    /// Bumped by a 0.5s timer while downloading so progress bars re-render and
    /// the completion/failure checks run (download progress lives on the
    /// downloader, which doesn't republish `center.models`).
    @State private var gateTick = 0

    /// Defaults seeded by the current device tier so the wizard opens
    /// already selecting what `DeviceTierAdvisor` would silently pick on
    /// a Skip — the user can override but they don't have to.
    private func tierAwareDefaults() -> (assistantID: String, visualRepoID: String) {
        let tier = DeviceTierAdvisor.current
        let assistant: String = {
            switch tier {
            case .max:                  return "qwen3-4b"             // best of our picks
            case .pro:                  return "qwen3-4b"             // pro can fit 4B
            case .mid:                  return "llama-3.2-3b"
            case .entry, .lite:         return "qwen2.5-coder-1.5b"
            }
        }()
        let visual: String = {
            switch tier {
            case .max:                  return "mlx-community/Qwen3-VL-4B-Instruct-4bit"
            case .pro:                  return "mlx-community/Qwen3-VL-2B-Instruct-4bit"
            case .mid, .entry, .lite:   return "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
            }
        }()
        // Only return picks we actually have curated entries for —
        // otherwise the radio would have nothing to land on.
        let safeAssistant = assistantPicks.contains(where: { $0.id == assistant })
            ? assistant : "qwen2.5-coder-1.5b"
        let safeVisual = visualPicks.contains(where: { $0.id == visual })
            ? visual : "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF"
        return (safeAssistant, safeVisual)
    }

    // MARK: - Curated options
    //
    // Hand-picked 3 per slot. Order = display order (recommended
    // first). The recommendations match what DeviceTierAdvisor
    // would have picked on a mid-tier device — keeps Skip and
    // pick-the-default users in the same state.

    private struct AssistantPick: Identifiable {
        let id: String           // matches AssistantModel.id
        let displayName: String
        let summary: String
        let sizeLabel: String
        let vendor: ModelVendor
        let capabilities: Set<ModelCapability>
    }
    private let assistantPicks: [AssistantPick] = [
        AssistantPick(
            id: "qwen2.5-coder-1.5b",
            displayName: "Qwen 2.5 Coder 1.5B",
            summary: "Fast, code-tuned, runs on every device. The safe default.",
            sizeLabel: "~900 MB",
            vendor: .qwen,
            capabilities: [.recommended]
        ),
        AssistantPick(
            id: "qwen3-4b",
            displayName: "Qwen 3 4B",
            summary: "Stronger reasoning with /think mode. Needs ≥ 6 GB process memory.",
            sizeLabel: "~2.3 GB",
            vendor: .qwen,
            capabilities: [.thinking, .best]
        ),
        AssistantPick(
            id: "llama-3.2-3b",
            displayName: "Llama 3.2 3B",
            summary: "Meta's general-purpose chat model. Good fallback if Qwen feels too terse.",
            sizeLabel: "~1.8 GB",
            vendor: .meta,
            capabilities: []
        ),
    ]

    private struct VisualPick: Identifiable {
        let id: String           // = repoID
        let displayName: String
        let summary: String
        let sizeLabel: String
        let vendor: ModelVendor
        let capabilities: Set<ModelCapability>
    }
    private let visualPicks: [VisualPick] = [
        VisualPick(
            id: "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF",
            displayName: "SmolVLM 2 500M",
            summary: "Tiny, fast multimodal. Already bundled — no download needed.",
            sizeLabel: "bundled",
            vendor: .huggingFace,
            capabilities: [.vision, .recommended]
        ),
        VisualPick(
            id: "mlx-community/Qwen3-VL-2B-Instruct-4bit",
            displayName: "Qwen 3 VL 2B",
            summary: "Compact vision-language model with /think mode. Mid-tier devices.",
            sizeLabel: "~1.7 GB",
            vendor: .qwen,
            capabilities: [.vision, .thinking]
        ),
        VisualPick(
            id: "mlx-community/Qwen3-VL-4B-Instruct-4bit",
            displayName: "Qwen 3 VL 4B",
            summary: "Sharper visual reasoning. Best on Pro / Max devices.",
            sizeLabel: "~2.9 GB",
            vendor: .qwen,
            capabilities: [.vision, .thinking, .best]
        ),
    ]

    // MARK: - Body

    var body: some View {
        List {
            Section {
                Text("Choose one chat model and one vision model. Downloads need a network connection; these models run on your device.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Section("Chat") { ForEach(assistantPicks) { assistantCard($0) } }
            Section("Vision") { ForEach(visualPicks) { visualCard($0) } }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .background { ODPageBackground().ignoresSafeArea() }
        .navigationTitle("Choose your models")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if phase == .picking { ctaBar }
        }
        .overlay {
            if phase == .downloading { gateOverlay }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard phase == .downloading else { return }
            gateTick &+= 1   // force progress bars to re-read downloader state
            if assistantSettled && visualSettled {
                HapticManager.notification(.success)
                onComplete()
            }
        }
        .onAppear {
            // Seed picks from device tier so the user lands on the right
            // recommendation. Avoid clobbering an explicit `commit()` /
            // re-entry — only seed when we're still on the static defaults.
            let defaults = tierAwareDefaults()
            if pickedAssistantID == "qwen2.5-coder-1.5b" {
                pickedAssistantID = defaults.assistantID
            }
            if pickedVisualRepoID == "ggml-org/SmolVLM2-500M-Video-Instruct-GGUF" {
                pickedVisualRepoID = defaults.visualRepoID
            }
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private func assistantCard(_ pick: AssistantPick) -> some View {
        let selected = pickedAssistantID == pick.id
        let verdict = MemoryAdvisor.verdictWithCurrentlyLoaded(for: pick.id)
        modelCard(
            selected: selected,
            vendor: pick.vendor,
            title: pick.displayName,
            summary: pick.summary,
            sizeLabel: pick.sizeLabel,
            caps: pick.capabilities,
            verdict: verdict
        ) {
            pickedAssistantID = pick.id
            HapticManager.impact(.light)
        }
    }

    @ViewBuilder
    private func visualCard(_ pick: VisualPick) -> some View {
        let selected = pickedVisualRepoID == pick.id
        // Vision models store their repoID directly, but MemoryAdvisor
        // needs the normalized key shape to look up real on-disk sizes.
        let verdict = MemoryAdvisor.verdictWithCurrentlyLoaded(
            for: LocalModelRegistry.visionMemoryAdvisorKey(for: pick.id)
        )
        modelCard(
            selected: selected,
            vendor: pick.vendor,
            title: pick.displayName,
            summary: pick.summary,
            sizeLabel: pick.sizeLabel,
            caps: pick.capabilities,
            verdict: verdict
        ) {
            pickedVisualRepoID = pick.id
            HapticManager.impact(.light)
        }
    }

    // Shared card layout for both sections — keeps the geometry +
    // selection animation identical.
    @ViewBuilder
    private func modelCard(
        selected: Bool,
        vendor: ModelVendor,
        title: String,
        summary: String,
        sizeLabel: String,
        caps: Set<ModelCapability>,
        verdict: MemoryAdvisor.Verdict,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(ODPalette.text)
                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                    Text(sizeLabel).font(.footnote).foregroundStyle(.secondary)
                    deviceFitNotice(verdict: verdict)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").foregroundStyle(ODPalette.text) }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Small inline warning that surfaces marginal/wontFit verdicts on
    /// a card. Hidden when the verdict is green so cards stay tidy for
    /// the recommended picks.
    @ViewBuilder
    private func deviceFitNotice(verdict: MemoryAdvisor.Verdict) -> some View {
        switch verdict {
        case .fitsComfortably:
            EmptyView()
        case .marginal(let warning):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(warning)
                    .font(T.mono(9))
                    .fixedSize(horizontal: false, vertical: true)

            }
            .foregroundColor(T.warn)
            .padding(.top, 4)
        case .wontFit(let warning):
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 8.5, weight: .bold))
                Text(warning)
                    .font(T.mono(9))
                    .fixedSize(horizontal: false, vertical: true)

            }
            .foregroundColor(T.bad)
            .padding(.top, 4)
        }
    }

    // MARK: - CTA bar

    private var ctaBar: some View {
        VStack(spacing: 6) {
            KPrimaryButton(
                label: ctaLabel,
                systemImage: needsAnyDownload ? "arrow.down.circle" : "arrow.right",
                trailing: nil
            ) {
                commit()
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background { ODPageBackground().ignoresSafeArea() }
    }

    // MARK: - Download gate
    //
    // Shown after the user taps Download & Continue when either pick still
    // needs downloading. Blocks entry until both finish — but with a Skip so a
    // slow / offline first launch can't lock the user out (camera works from
    // the bundled models regardless; the picks just keep downloading in the
    // background after Skip).

    private var assistantDLModel: DownloadableModel? {
        center.models.first { $0.id == pickedAssistantID }
    }
    private var visualDLModel: DownloadableModel? {
        center.models.first { $0.id == pickedVisualRepoID }
    }
    /// "Settled" = on disk, OR no catalog entry to track (so we never hang the
    /// gate waiting on something that can't report readiness).
    private var assistantSettled: Bool { assistantDLModel.map { $0.isReady } ?? true }
    private var visualSettled: Bool { visualDLModel.map { $0.isReady } ?? true }

    private func isFailed(_ m: DownloadableModel?) -> Bool {
        guard let s = m?.state else { return false }
        if case .failed = s { return true }
        return false
    }
    private var anyDownloadFailed: Bool {
        isFailed(assistantDLModel) || isFailed(visualDLModel)
    }

    /// Full-screen blocking overlay for the download phase: a dimming scrim
    /// over the (now inert) picker plus the gate panel pinned to the bottom.
    /// The scrim is what stops the scroll content from showing through the
    /// gate copy — the panel itself is opaque too, belt-and-suspenders.
    private var gateOverlay: some View {
        ScrollView { gateBar }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ODPageBackground().ignoresSafeArea() }
        .transition(.opacity)
    }

    private var gateBar: some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Setting up your models")
                    .font(T.sans(17, .semibold))
                    .foregroundColor(T.ink)
                Text("Downloading your picks so everything runs on-device. One-time setup — it works offline afterwards. The camera already works from the built-in model; you can Skip and your picks keep downloading in the background (track them in the Models tab).")
                    .font(T.sans(11))
                    .foregroundColor(T.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
            }

            VStack(spacing: 10) {
                gateProgressRow(label: "Assistant", model: assistantDLModel, settled: assistantSettled)
                gateProgressRow(label: "Vision", model: visualDLModel, settled: visualSettled)
            }

            if anyDownloadFailed {
                Button { retryDownloads() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        Text("Retry download").font(T.mono(11, .semibold))
                    }
                    .foregroundColor(T.bad)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).fill(T.bad.opacity(0.10)))
                    .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).stroke(T.bad.opacity(0.4), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }

            Button { onComplete() } label: {
                Text("Skip for now — finish in Models")
                    .font(T.mono(10, .semibold))
                    .tracking(0.5)
                    .foregroundColor(T.ink3)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(
            // Solid panel (no gradient): a rounded card edge fading the scrim
            // into a fully opaque surface so the gate copy always reads clean.
            ZStack {
                T.bg
                RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                    .fill(T.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                            .stroke(T.glassBorder, lineWidth: 0.5)
                    )
                    .padding(.horizontal, 8)
            }
            .ignoresSafeArea(edges: .bottom)
        )
    }

    @ViewBuilder
    private func gateProgressRow(label: String, model: DownloadableModel?, settled: Bool) -> some View {
        let failed = isFailed(model)
        let progress = settled ? 1.0 : (model?.progress ?? 0)
        HStack(spacing: 10) {
            ZStack {
                if settled {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(T.good)
                } else if failed {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(T.bad)
                } else {
                    ProgressView().scaleEffect(0.7).tint(T.accent)
                }
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    KMono(text: label, size: 11, color: T.ink2)
                    Spacer()
                    KMono(text: settled ? "ready" : (failed ? "failed" : "\(Int(progress * 100))%"),
                          size: 10, color: settled ? T.good : (failed ? T.bad : T.ink3))
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous).fill(T.rule).frame(height: 3)
                        RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                            .fill(settled ? T.good : (failed ? T.bad : T.accent))
                            .frame(width: max(0, min(1, progress)) * geo.size.width, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .kGlass(cornerRadius: StudioRadius.tile, fallbackFill: T.surface)
    }

    private func retryDownloads() {
        if let a = assistantDLModel, !a.isReady { a.start() }
        if let v = visualDLModel, !v.isReady { v.start() }
        HapticManager.impact(.light)
    }

    private var ctaLabel: String {
        if needsAnyDownload {
            return "Download & Continue · \(downloadSizeLabel)"
        }
        return "Continue"
    }

    /// True iff at least one picked model isn't already on disk.
    private var needsAnyDownload: Bool {
        !pickedAssistantIsReady || !pickedVisualIsReady
    }

    private var pickedAssistantIsReady: Bool {
        center.models.first(where: { $0.id == pickedAssistantID })?.isReady ?? false
    }
    private var pickedVisualIsReady: Bool {
        center.models.first(where: { $0.id == pickedVisualRepoID })?.isReady ?? false
    }

    /// Combined download-size label for the CTA. Sums only the picks
    /// that aren't already on disk.
    private var downloadSizeLabel: String {
        var total: Double = 0
        if !pickedAssistantIsReady,
           let pick = assistantPicks.first(where: { $0.id == pickedAssistantID }) {
            total += approxGB(from: pick.sizeLabel)
        }
        if !pickedVisualIsReady,
           let pick = visualPicks.first(where: { $0.id == pickedVisualRepoID }) {
            total += approxGB(from: pick.sizeLabel)
        }
        if total <= 0 { return "ready" }
        if total < 1 { return String(format: "≈%d MB", Int(total * 1024)) }
        return String(format: "≈%.1f GB", total)
    }

    /// Lossy parse of a "~1.7 GB" / "~520 MB" / "bundled" label.
    /// Returns 0 for "bundled" / "ready" / unparseable strings.
    private func approxGB(from label: String) -> Double {
        let cleaned = label
            .lowercased()
            .replacingOccurrences(of: "~", with: "")
            .replacingOccurrences(of: "≈", with: "")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.contains("bundled") || cleaned.contains("ready") { return 0 }
        // Split numeric prefix
        let parts = cleaned.split(separator: " ", maxSplits: 1)
        guard let num = parts.first.flatMap({ Double($0) }) else { return 0 }
        if cleaned.contains("mb") { return num / 1024.0 }
        if cleaned.contains("gb") { return num }
        return 0
    }

    // MARK: - Commit

    /// Save picks to AppSettings, kick off downloads, dismiss onboarding.
    /// Downloads run in the background — the user lands on the home tab
    /// where the Models tab Installing section surfaces progress.
    private func commit() {
        // Save assistant pick.
        settings.assistantModelID = pickedAssistantID
        settings.hasPickedAssistantModel = true

        // Save visual pick — written as the camera-visual repo ID so
        // the lens tab picks it up without further plumbing.
        LocalModelRegistry.setVisionSelection(pickedVisualRepoID, settings: settings)
        settings.hasPickedCameraVisualModel = true

        // Trigger downloads where needed.
        if let assistant = center.models.first(where: { $0.id == pickedAssistantID }),
           !assistant.isReady {
            assistant.start()
        }
        if let visual = center.models.first(where: { $0.id == pickedVisualRepoID }),
           !visual.isReady {
            visual.start()
        }

        // If both picks are already on disk, enter right away. Otherwise show
        // the download gate, which blocks entry until both finish (with a Skip
        // escape so a slow/offline launch can't lock the user out).
        if assistantSettled && visualSettled {
            HapticManager.notification(.success)
            onComplete()
        } else {
            HapticManager.impact(.medium)
            withAnimation { phase = .downloading }
        }
    }
}
