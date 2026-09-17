import SwiftUI
import Combine

// MARK: - DiagnosticsView
//
// The in-app debug surface. One screen to answer "what just happened / why did
// it crash": a prior-crash banner with the breadcrumb trail, the live system
// snapshot (memory + thermal that decide on-device survival), the rolling log,
// and MetricKit reports — all exportable to share when filing an issue.

struct DiagnosticsView: View {
    @Environment(\.koduTheme) private var T
    @ObservedObject private var metric = MetricKitHandler.shared

    @State private var entries: [DiagEntry] = []
    @State private var minLevel: DiagLevel = .info
    @State private var snapshot = SystemSnapshot.header()

    @StateObject private var analyzer = DiagnosticsAnalyzer()
    @StateObject private var edge0Validation = Edge0DeviceValidationRunner()
    @StateObject private var edge0SpeedAB = Edge0SpeedABRunner()
    @StateObject private var prerouter = Edge0PrerouterDownloadController()
    @State private var sentinelResult = ""

    private let crash = CrashReporter.shared.lastCrash
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if let crash { crashSection(crash) }
            analysisSection
            edge0ValidationSection
            edge0PrerouterSection
            edge0SpeedABSection
            deploymentSentinelSection
            snapshotSection
            logSection
            if !metric.entries.isEmpty { metricSection }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: Diagnostics.shared.exportText()) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button(role: .destructive) {
                        Diagnostics.shared.clear(); refresh()
                    } label: { Label("Clear log", systemImage: "trash") }
                    Button(role: .destructive) {
                        metric.clear()
                    } label: { Label("Clear MetricKit", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
    }

    private func refresh() {
        entries = Diagnostics.shared.recentEntries(minLevel: minLevel).reversed()
        snapshot = SystemSnapshot.header()
    }

    // MARK: - Sections

    /// Developer-only data-preservation probe. Write in build A, install
    /// build B as an update, then Check: missing means the installer wiped
    /// the app container (downloaded models included).
    private var deploymentSentinelSection: some View {
        Section {
            Button("Write persistence sentinel") {
                sentinelResult = "written · " + DeploymentSentinel.write()
            }
            Button("Check persistence sentinel") {
                if let value = DeploymentSentinel.read() {
                    sentinelResult = "survived · " + value
                } else {
                    sentinelResult = "MISSING — app data did not survive the install"
                }
            }
            Button(role: .destructive) {
                DeploymentSentinel.delete()
                sentinelResult = "sentinel deleted"
            } label: {
                Text("Delete sentinel")
            }
            if !sentinelResult.isEmpty {
                Text(sentinelResult)
                    .font(.caption)
                    .foregroundStyle(
                        sentinelResult.hasPrefix("MISSING") ? .red : .secondary
                    )
            }
        } header: {
            Text("Deployment Persistence")
        } footer: {
            Text("Install build A → write the sentinel → install build B as an update → Check. If it is missing, your installer deleted the app container. Use an in-place update (Xcode/devicectl) or re-import a model copy from Files instead of re-downloading.")
        }
    }

    /// Developer-only physical-device A→Z runner for the Edge0 native
    /// families. Drives the production Assistant path; each stage reports
    /// independently. See `Edge0DeviceValidationRunner` for the stage
    /// contract.
    private var edge0ValidationSection: some View {
        Section {
            Picker("Family", selection: $edge0Validation.family) {
                ForEach(Edge0ModelFamily.allCases, id: \.self) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .pickerStyle(.segmented)
            .disabled(edge0Validation.isRunning)

            Picker("Execution mode", selection: $edge0Validation.executionMode) {
                if edge0Validation.family == .qwen35MoE {
                    Text("35B Exact").tag(Edge0ExecutionMode.exact)
                    Text("35B Bounded Prefetch").tag(Edge0ExecutionMode.boundedPrefetch)
                    Text("35B Staged Prefill").tag(Edge0ExecutionMode.staged)
                } else {
                    Text("Exact (oracle)").tag(Edge0ExecutionMode.exact)
                    Text("Bounded prefetch").tag(Edge0ExecutionMode.boundedPrefetch)
                    Text("Staged (experiment)").tag(Edge0ExecutionMode.staged)
                    Text("Staged + prerouter").tag(Edge0ExecutionMode.stagedPrerouter)
                }
            }
            .pickerStyle(.segmented)
            .disabled(edge0Validation.isRunning)
            .onChange(of: edge0Validation.family) { _, family in
                if family == .qwen35MoE,
                   edge0Validation.executionMode != .exact,
                   edge0Validation.executionMode != .boundedPrefetch,
                   edge0Validation.executionMode != .staged {
                    edge0Validation.executionMode = .exact
                }
            }
            if edge0Validation.family == .qwen35MoE {
                Text("35B supports exact true-router, bounded prefetch, and staged prefill (staged·microbatch4 + bounded decode — the production default). Readahead hints and the advisory prerouter are device-A/B candidates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Pool capacity", selection: $edge0Validation.poolCapacityMiB) {
                Text("Auto").tag(0)
                Text("256 MiB").tag(256)
                Text("512 MiB").tag(512)
                Text("1 GiB").tag(1024)
                Text("2 GiB").tag(2048)
            }
            .disabled(edge0Validation.isRunning)

            Picker("Expert reads", selection: $edge0Validation.readConcurrency) {
                Text("2").tag(2)
                Text("4").tag(4)
                Text("6").tag(6)
            }
            .pickerStyle(.segmented)
            .disabled(edge0Validation.isRunning)

            Toggle("Component profiling", isOn: $edge0Validation.profilingEnabled)
                .disabled(edge0Validation.isRunning)

            if edge0Validation.family == .qwen35MoE {
                // Phase 5M / 5J candidates. Both are numerically inert with
                // respect to the true router; they only change WHEN bytes are
                // asked for. They are captured at model load, so a run must
                // be restarted for a change to take effect.
                Toggle("Readahead hints (5M)", isOn: $edge0Validation.readaheadHints)
                    .disabled(edge0Validation.isRunning)
                    .accessibilityIdentifier("edge0ValidationReadahead")
                Toggle("Advisory prerouter (5J)", isOn: $edge0Validation.advisoryPrerouter)
                    .disabled(edge0Validation.isRunning)
                    .accessibilityIdentifier("edge0ValidationAdvisoryPrerouter")
                Text("Readahead issues a kernel F_RDADVISE over each expert slice before its read; the advisory prerouter prefetches the next decode token's experts. Neither changes generated output. Applied at the next model load.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                Task { await edge0Validation.run() }
            } label: {
                Label(
                    edge0Validation.isRunning
                        ? "Running Edge0 validation…"
                        : "Run Edge0 Device Validation",
                    systemImage: "checklist"
                )
            }
            .disabled(edge0Validation.isRunning)

            if !edge0Validation.deviceSummary.isEmpty {
                Text(edge0Validation.deviceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Edge0DeviceValidationRunner.Stage.allCases) { stage in
                let result = edge0Validation.results[stage]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: edge0StatusIcon(result?.status))
                        .foregroundStyle(edge0StatusColor(result?.status))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(stage.rawValue). \(stage.title)")
                            .font(.subheadline)
                        if let detail = edge0StatusDetail(result?.status) {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !edge0Validation.isRunning, !edge0Validation.results.isEmpty {
                ShareLink(item: edge0Validation.summaryText) {
                    Label("Share validation summary", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("Edge0 Device Validation")
        } footer: {
            Text("Runs the real Assistant path (no test-only model instance). Results contain timings and counts only — never prompt or generated text.")
        }
    }

    /// Optional learned prerouter: artifact provenance and the ONLY place it
    /// can be fetched (explicit incremental download; never during
    /// generation, never as part of the base checkpoint).
    private var edge0PrerouterSection: some View {
        Section {
            HStack {
                Text("Advisory prerouter (optional)")
                Spacer()
                Text(prerouter.summary)
                    .font(.caption)
                    .foregroundStyle(prerouter.valid ? .green : .secondary)
            }
            if !prerouter.detail.isEmpty {
                Text(prerouter.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if prerouter.isDownloading {
                ProgressView(value: prerouter.progress) {
                    Text("Downloading predictor… \(Int(prerouter.progress * 100))%")
                        .font(.caption2)
                }
            } else {
                Button {
                    prerouter.download()
                } label: {
                    Label(
                        prerouter.present
                            ? "Re-download predictor (132 MB)"
                            : "Download predictor (132 MB)",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(prerouter.busy)
            }
        } header: {
            Text("35B Learned Prerouter")
        } footer: {
            Text("Advisory only: predictions can start speculative expert reads; the true router still selects every executed expert. Absent = the model runs normally.")
                .font(.caption2)
        }
        .task { prerouter.refresh() }
    }

    /// One-button controlled A/B for the 35B family: Exact vs Bounded
    /// Prefetch through the production Assistant path with a fixed profile.
    private var edge0SpeedABSection: some View {
        Section {
            Picker("Diagnostic", selection: $edge0SpeedAB.kind) {
                ForEach(Edge0DiagnosticKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .disabled(edge0SpeedAB.isRunning)

            Picker("Minimum idle", selection: $edge0SpeedAB.recoverySeconds) {
                Text("0s (none)").tag(0)
                Text("30s").tag(30)
                Text("60s").tag(60)
                Text("120s").tag(120)
            }
            .disabled(edge0SpeedAB.isRunning)

            if edge0SpeedAB.isRunning {
                Button(role: .destructive) {
                    edge0SpeedAB.cancel()
                } label: {
                    Label("Cancel Benchmark", systemImage: "stop.circle")
                }
            } else {
                Button {
                    Task { await edge0SpeedAB.run() }
                } label: {
                    Label("Run 35B Speed Diagnostic", systemImage: "speedometer")
                }
            }

            if !edge0SpeedAB.status.isEmpty {
                Text(edge0SpeedAB.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !edge0SpeedAB.results.isEmpty {
                ForEach(edge0SpeedAB.results) { run in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(run.label)")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(run.scored ? "scored" : "warm-up")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let error = run.error {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        } else {
                            Text(
                                "gen \(run.generatedTokens) · decode \(String(format: "%.2f", run.decodeTokensPerSecond)) tok/s"
                                + " · prefill \(String(format: "%.1f", run.prefillSeconds))s"
                                + " · e2e \(String(format: "%.2f", run.endToEndTokensPerSecond)) tok/s"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(
                                "mode \(run.effectiveMode) · pool \(run.poolSlots) slots · stop \(run.stopReason)"
                                + (edge0SpeedAB.kind == .computeAB
                                    ? " · readback \(run.routerReadbackEffective == 1 ? "batched" : "per-token")"
                                    : "")
                                + (edge0SpeedAB.kind == .readaheadAB
                                    ? " · readahead \(run.readaheadEffective ? "on" : "off")"
                                    : "")
                                + (edge0SpeedAB.kind == .readsAB
                                    ? " · reads \(run.readsEffective)"
                                    : "")
                                + (run.sustainedEvidence ? "" : " · sustained evidence insufficient")
                                + (run.sequenceMatch == false ? " · OUTPUT DIFFERS" : "")
                            )
                            .font(.caption2)
                            .foregroundStyle(
                                run.sequenceMatch == false
                                    ? Color.red : Color.secondary
                            )
                        }
                    }
                }
            }

            if !edge0SpeedAB.driftDiagnosis.isEmpty {
                Text(edge0SpeedAB.driftDiagnosis)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            if !edge0SpeedAB.decision.isEmpty {
                Text(edge0SpeedAB.decision)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !edge0SpeedAB.isRunning, !edge0SpeedAB.results.isEmpty {
                ShareLink(item: edge0SpeedAB.summaryText) {
                    Label("Share A/B summary", systemImage: "square.and.arrow.up")
                }
            }
        } header: {
            Text("35B Speed Diagnostic — Exact / Bounded Prefetch")
        } footer: {
            Text("Fixed profile: 512 MiB pool, 4 reads, Thinking Off, greedy, max 64 tokens, one public prompt. Single scored Exact is the runner-completion check (warm-up → 60 s recovery → one scored run); A/B uses counterbalanced Exact → Bounded → Bounded → Exact; Exact drift runs three Exact trials. Every scored trial waits the configured minimum idle interval plus thermal recovery (bounded, cancellable). Your settings are restored afterwards; production defaults are not changed.")
        }
    }

    private func edge0StatusIcon(_ status: Edge0DeviceValidationRunner.Status?) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "arrow.triangle.2.circlepath"
        case .skipped: return "minus.circle"
        case .pending, .none: return "circle"
        }
    }

    private func edge0StatusColor(_ status: Edge0DeviceValidationRunner.Status?) -> Color {
        switch status {
        case .passed: return .green
        case .failed: return .red
        case .running: return .accentColor
        case .skipped: return .secondary
        case .pending, .none: return .secondary
        }
    }

    private func edge0StatusDetail(_ status: Edge0DeviceValidationRunner.Status?) -> String? {
        switch status {
        case .passed(let detail), .failed(let detail), .skipped(let detail):
            return detail
        case .pending, .running, .none:
            return nil
        }
    }

    private func crashSection(_ c: CrashReporter.CrashInfo) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Label("Previous session ended in a \(c.kind)", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(c.detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !c.trail.isEmpty {
                    DisclosureGroup("Breadcrumb trail (\(c.trail.count))") {
                        ForEach(Array(c.trail.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: { Text("Last crash") }
    }

    // MARK: - On-device AI analysis

    /// Feeds the crash trail + recent warnings/errors + system snapshot to the
    /// selected assistant model and streams back a plain-English diagnosis —
    /// entirely on-device.
    private var analysisSection: some View {
        Section {
            if analyzer.running {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(analyzer.output.isEmpty ? "Analyzing on-device…" : "Analyzing…")
                        .font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { analyzer.stop() }
                        .font(.footnote)
                }
            } else {
                Button {
                    analyzer.analyze(buildDiagnosticsPrompt())
                } label: {
                    Label(analyzer.output.isEmpty ? "Analyze with on-device AI" : "Re-analyze",
                          systemImage: "sparkles")
                }
            }
            if !analyzer.output.isEmpty {
                Text(analyzer.output)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
            if let err = analyzer.error {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("On-device analysis")
        } footer: {
            Text("Runs the selected assistant model locally — nothing leaves your device.")
                .font(.caption2)
        }
    }

    /// Diagnostics context handed to the model — shared with the chat
    /// "Diagnose app errors" action (see Diagnostics.analysisContext()).
    private func buildDiagnosticsPrompt() -> String {
        Diagnostics.shared.analysisContext()
    }

    private var snapshotSection: some View {
        Section {
            Text(snapshot)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
        } header: { Text("System") }
    }

    private var logSection: some View {
        Section {
            Picker("Level", selection: $minLevel) {
                ForEach(DiagLevel.allCases, id: \.self) { lvl in
                    Text(lvl.label).tag(lvl)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: minLevel) { _, _ in refresh() }

            if entries.isEmpty {
                Text("No log entries at this level.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(e.level.label)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color(for: e.level))
                            Text(e.category)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Text(e.message)
                            .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        } header: { Text("Log · \(entries.count)") }
    }

    private var metricSection: some View {
        Section {
            ForEach(metric.entries) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.kind.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(e.kind == "crash" ? .red : .secondary)
                    Text(e.summary)
                        .font(.system(size: 11, design: .monospaced))
                }
            }
        } header: { Text("MetricKit reports") }
    }

    private func color(for level: DiagLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .notice: return .teal
        case .warning: return .orange
        case .error, .fault: return .red
        }
    }
}

// MARK: - DiagnosticsAnalyzer
//
// Drives a one-shot analysis through SafeOnDeviceAnalysisCoordinator. It never
// uses a heavyweight chat selection: Apple's on-device system model is preferred
// and a temporary lightweight local model is the offline fallback.

@MainActor
final class DiagnosticsAnalyzer: ObservableObject {
    @Published var output = ""
    @Published var running = false
    @Published var error: String?

    private let systemPrompt = """
    You are an on-device diagnostics analyst for OnDevice, an iOS app that runs \
    local AI models (MLX / Core ML) fully offline. You are given a system \
    snapshot (memory, thermal, device), the last crash if any, and recent \
    warnings/errors from the app's log. Respond with: (1) the most likely root \
    cause(s), ranked; (2) concrete fixes or user actions (e.g. free memory, \
    re-download a model, pick a smaller model, let the device cool). Be concise \
    and specific. If nothing looks wrong, say the device looks healthy. Do not \
    invent log lines that aren't present.
    """

    func analyze(_ diagnostics: String) {
        guard !running else { return }
        output = ""
        error = nil
        running = true
        SafeOnDeviceAnalysisCoordinator.shared.analyze(
            prompt: diagnostics,
            instructions: systemPrompt,
            maxTokens: 700,
            onToken: { [weak self] chunk in
                Task { @MainActor in self?.output += chunk }
            },
            onComplete: { [weak self] routeError in
                Task { @MainActor in
                    guard let self else { return }
                    self.running = false
                    if let routeError, !routeError.isEmpty {
                        self.error = routeError
                    } else if self.output.isEmpty {
                        self.error = "The analysis model returned no response — try again in a moment."
                    }
                }
            }
        )
    }

    func stop() {
        SafeOnDeviceAnalysisCoordinator.shared.cancel()
        running = false
    }
}


// MARK: - Edge0PrerouterDownloadController
//
// Artifact provenance + the explicit single-file incremental download for
// the optional 35B advisory prerouter. Uses the existing downloader and
// destination; never re-downloads the base checkpoint.

@MainActor
private final class Edge0PrerouterDownloadController: ObservableObject {
    @Published private(set) var present = false
    @Published private(set) var valid = false
    @Published private(set) var heads = 0
    @Published private(set) var bytes: UInt64 = 0
    @Published private(set) var summary = "checking…"
    @Published private(set) var detail = ""
    @Published private(set) var isDownloading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var busy = false

    private var manager: HFModelDownloadManager?
    private var stateObserver: AnyCancellable?

    private var destination: URL? {
        ModelDownloadCenter.shared.make35BPrerouterDownloader()?.destination
    }

    func refresh() {
        guard let destination else {
            summary = "35B model not installed"
            detail = ""
            present = false
            valid = false
            return
        }
        let url = destination.appendingPathComponent(
            Edge0_35BModelArtifacts.prerouterFileName
        )
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        present = size > 0
        bytes = size
        if !present {
            summary = "not installed"
            detail = "Optional: \(Int64(Edge0_35BModelArtifacts.prerouterFileSize).formattedBytes). Download it here only if you want the learned predictor for the A/B."
            valid = false
            heads = 0
            return
        }
        Task {
            let loaded = try? await Edge0_35BPrerouter.load(directory: destination)
            await MainActor.run {
                valid = loaded != nil
                heads = loaded?.headCount ?? 0
                summary = valid ? "installed · \(heads) heads" : "present but INVALID"
                detail = "\(Int64(size).formattedBytes) on disk"
                    + (valid ? "" : " · expected \(Int64(Edge0_35BModelArtifacts.prerouterFileSize).formattedBytes); re-download to repair")
            }
        }
    }

    func download() {
        guard let manager = ModelDownloadCenter.shared
            .make35BPrerouterDownloader() else {
            summary = "35B model not installed"
            return
        }
        self.manager = manager
        busy = true
        isDownloading = true
        progress = 0
        summary = "downloading…"
        stateObserver = manager.$state.sink { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                switch state {
                case .failed(let message):
                    self.isDownloading = false
                    self.busy = false
                    self.summary = "download failed"
                    self.detail = message
                case .ready:
                    self.isDownloading = false
                    self.busy = false
                    self.refresh()
                default:
                    self.progress = manager.progress
                }
            }
        }
        manager.start()
    }
}
