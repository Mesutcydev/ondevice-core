import SwiftUI
import OnDeviceUI

/// A retained workspace. Opening it never enables the listener or loads a model.
/// All networking, authentication and lifecycle remain owned by LocalAPIManager.
///
/// Uses OnDeviceLAS as a design reference: listener controls, model runtime,
/// device health and copyable client setup. Listener state, model residency
/// and LAN availability remain separate facts.
struct LocalAPIServerView: View {
    let onOpenMenu: () -> Void
    @EnvironmentObject private var store: ODStore
    @Environment(\.odSidebarPinned) private var sidebarPinned
    @ObservedObject private var manager = LocalAPIManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isStopping = false
    @State private var revealsKey = false
    @State private var showModels = false
    @State private var showPortEditor = false
    @State private var confirmsKeyRotation = false
    @State private var format: LocalAPIClientSetup.Format = .openAI
    @AppStorage("localAPIToolCallingEnabled") private var toolCallingEnabled = true
    @AppStorage("localAPIParallelToolCallsEnabled") private var parallelToolCallsEnabled = true
    @AppStorage("localAPIReasoningEnabled") private var reasoningEnabled = true
    @AppStorage("localAPIStrictToolSchemasEnabled") private var strictToolSchemasEnabled = false
    @AppStorage("localAPIAutoLoadModel") private var autoLoadModel = false
    @AppStorage("localAPIMaxOutputTokens") private var maxOutputTokens = 4096

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    operatorHeader
                    summary
                    modelCard
                    networkBanner
                    health
                    connection(port: currentPort)
                    quickStart(port: currentPort)
                    configuration
                    generation
                    LocalAPIEndpointsView(setup: clientSetup)
                    diagnosticsLink
                    notes
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, ODLayout.pageInset)
                .padding(.top, ODLayout.elementGap)
                .padding(.bottom, ODLayout.groupGap)
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("API server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(store.selectedTab == .apiServer ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if !sidebarPinned {
                    ToolbarItem(placement: .topBarLeading) {
                        ODAppMenuButton(action: onOpenMenu).accessibilityIdentifier("navigation.menu")
                    }
                }
            }
            .onAppear { manager.refreshAddresses() }
            // A revealed bearer key must not survive into the app switcher
            // snapshot or a locked screen.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { revealsKey = false }
            }
            .onChange(of: store.selectedTab) { _, selection in
                if selection != .apiServer { revealsKey = false }
            }
            .onDisappear { revealsKey = false }
            .sheet(isPresented: $showModels) {
                AssistantModelPickerView(downloadedOnly: true, allowsAPIProviders: false, allowsApplePrivateCloud: false)
            }
            .sheet(isPresented: $showPortEditor) {
                LocalAPIPortSheet()
            }
            .alert("Rotate API key?", isPresented: $confirmsKeyRotation) {
                Button("Rotate", role: .destructive) {
                    manager.rotateKey()
                    ToastCenter.shared.info("API key rotated", detail: "Update clients before their next request.")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Clients using the current key stop working until they use the new one.")
            }
        }
    }

    // The LAS overview's operator identity, network strip and live parser are
    // kept together at the top of this single retained workspace.
    private var operatorHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token AI")
                    .font(.title3.weight(.bold))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Text("LOCAL API · ON DEVICE")
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            }
            Spacer(minLength: 4)
            NavigationLink {
                DiagnosticsView()
            } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ODPalette.text)
                    .frame(width: 42, height: 42)
                    .background(ODPalette.input,
                                in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(ODPalette.line, lineWidth: 1)
                    }
            }
            .buttonStyle(APIConnectionPressStyle())
            .accessibilityLabel("On-device debugger")
            .accessibilityIdentifier("api.debugger")
        }
        .padding(.vertical, 8)
    }

    private var networkBanner: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(networkStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "network").foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(statusTitle). \(networkStatus)")

            networkQuickActions

            if let host = manager.addresses.first {
                Divider().overlay(ODPalette.line)
                shareConnection(host: host, port: currentPort, identifier: "api.share.overview")
            }
        }
        .apiCard(padding: 16, radius: ODLayout.panelCorner)
    }

    private var networkQuickActions: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    copyIPButton
                    Divider().overlay(ODPalette.line)
                    copyAPIButton
                    Divider().overlay(ODPalette.line)
                    copyKeyButton
                }
            } else {
                HStack(spacing: 0) {
                    copyIPButton
                    networkActionDivider
                    copyAPIButton
                    networkActionDivider
                    copyKeyButton
                }
            }
        }
        .background(ODPalette.input,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(ODPalette.line, lineWidth: 1)
        }
    }

    private var networkActionDivider: some View {
        Rectangle()
            .fill(ODPalette.line)
            .frame(width: 1, height: 24)
            .accessibilityHidden(true)
    }

    private var copyIPButton: some View {
        networkAction("Copy IP", symbol: "doc.on.doc", enabled: !manager.addresses.isEmpty) {
            guard let host = manager.addresses.first else { return }
            copy(host, feedback: "IP copied")
        }
    }

    private var copyAPIButton: some View {
        networkAction("Copy API", symbol: "link", enabled: !manager.addresses.isEmpty) {
            guard let host = manager.addresses.first else { return }
            copy("http://\(host):\(currentPort)/v1", feedback: "API URL copied")
        }
    }

    private var copyKeyButton: some View {
        networkAction("Copy key", symbol: "key", enabled: true) {
            copy(manager.apiKey, feedback: "API key copied")
        }
    }

    private func networkAction(_ title: String, symbol: String, enabled: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 21 : 14, weight: .medium))
                    .foregroundStyle(ODPalette.accent)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ODPalette.text)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(APIConnectionPressStyle())
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private var networkStatus: String {
        guard let host = manager.addresses.first else { return "Local API · waiting for LAN" }
        return "Local API · \(host):\(currentPort)"
    }

    private var currentPort: UInt16 {
        if case .running(let port) = manager.state { return port }
        return LocalAPIValidation.validPort(settings.localAPIPort) ?? 11434
    }

    private var liveActivity: LocalAPIServerActivity {
        let listener: LocalAPIServerActivity.Listener
        switch manager.state {
        case .stopped: listener = .stopped
        case .starting: listener = .starting
        case .running: listener = .running
        case .failed: listener = .failed
        }
        let model: LocalAPIServerActivity.Model
        if assistant.activeExecutionLocation.isCloud {
            model = .remote
        } else {
            switch assistant.state {
            case .unloaded: model = .unloaded
            case .loading: model = .loading
            case .ready: model = assistant.isModelLoaded ? .ready : .unloaded
            case .generating: model = assistant.isModelLoaded ? .generating : .unloaded
            case .failed: model = .failed
            }
        }
        return LocalAPIServerActivity(listener: listener, model: model, isStopping: isStopping)
    }

    private var clientSetup: LocalAPIClientSetup {
        LocalAPIClientSetup(host: manager.addresses.first ?? "localhost", port: currentPort,
                            modelID: assistant.activeExecutionLocation.isCloud ? "" : assistant.activeSelectionID)
    }

    // MARK: - Model and listener cards

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            operatorLabel("MODEL RUNTIME")
            modelRow
            if !assistant.activeDisplayName.isEmpty && !assistant.activeExecutionLocation.isCloud {
                HStack(alignment: .top, spacing: 8) {
                    Text(assistant.activeSelectionID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("api.model.id")
                    copyButton("Copy model ID", identifier: "api.model.id.copy") {
                        copy(assistant.activeSelectionID, feedback: "Model ID copied")
                    }
                }
            }
            if assistant.activeExecutionLocation.isCloud {
                Label("Choose a downloaded local model to serve API requests. The server does not use cloud models.",
                      systemImage: "externaldrive")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .failed(let message) = assistant.state {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("api.model.error")
            }
            if case .running = manager.state { activityRow }
        }
        .apiCard(padding: 20, radius: ODLayout.panelCorner)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            operatorLabel("LOCAL API SERVER")
            HStack(alignment: .center, spacing: 12) {
                statusGlyph
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Server status").accessibilityValue(statusAccessibilityValue)
            .accessibilityIdentifier("api.status")

            if case .failed(let message) = manager.state {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LocalAPIActivityView(activity: liveActivity, tokenRate: assistant.tokenRate,
                                 isVisible: store.selectedTab == .apiServer)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { lifecycleButton; restartButton }
                VStack(spacing: 10) { lifecycleButton; restartButton }
            }

            if case .running = manager.state, !modelReady {
                Label("Requests return 503 until a model is loaded.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Text("OpenAI · Anthropic · Ollama")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .apiCard(padding: 20, radius: ODLayout.panelCorner)
    }

    private func operatorLabel(_ title: String, trailing: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption.weight(.bold).monospaced())
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.caption2.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusGlyph: some View {
        ZStack {
            Circle().fill(statusColor.opacity(0.14))
            Image(systemName: statusSymbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
        }
        .frame(width: 40, height: 40)
    }

    /// Runtime detail belongs to the running listener. Other workspaces can
    /// share this model, so generation alone does not prove an API request.
    private var activityRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform")
                .font(.body.weight(.semibold))
                .foregroundStyle(isAnswering ? Color.green : .secondary)
                .symbolEffect(.variableColor.iterative, isActive: isAnswering && !reduceMotion)
                .frame(width: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(activityTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                    Spacer(minLength: 0)
                    if isAnswering, assistant.tokenRate > 0 {
                        Text(String(format: "%.1f tok/s", assistant.tokenRate))
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(activityDetail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity")
        .accessibilityValue("\(activityTitle). \(activityDetail)")
        .accessibilityIdentifier("api.activity")
    }

    private var modelRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    modelPickerButton
                    modelAction
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(spacing: 10) {
                    modelPickerButton
                    modelAction
                }
            }
        }
    }

    private var modelPickerButton: some View {
        Button {
            store.requestExclusiveOperation("Changing the API server model") { showModels = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "cube")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, height: 36)
                    .background(ODPalette.input,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(modelName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ODPalette.text)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    HStack(spacing: 6) {
                        if modelIsLoading {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                        }
                        Text(modelStatus)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model, \(modelName), \(modelStatus)")
        .accessibilityHint("Choose a downloaded model")
        .accessibilityIdentifier("api.model")
    }

    @ViewBuilder private var modelAction: some View {
        if assistant.activeDisplayName.isEmpty || assistant.activeExecutionLocation.isCloud {
            Button("Get a model") { store.selectedTab = .models }
                .buttonStyle(APIActionButtonStyle(tone: .secondary, compact: true))
                .accessibilityIdentifier("api.model.get")
        } else if canLoadModel {
            Button("Load") {
                guard assistant.selectedModelIsInstalled else {
                    store.selectedTab = .models
                    ToastCenter.shared.info("Download the model first", detail: "Choose a model in Models to download it, then return to the API server.")
                    return
                }
                store.requestExclusiveOperation("Loading the API server model") {
                    Task { await assistant.load(allowStorageFallback: false, reselectFromSettings: false) }
                }
            }
                .buttonStyle(APIActionButtonStyle(tone: .secondary, compact: true))
                .accessibilityIdentifier("api.model.load")
        } else if modelIsLoading {
            Button("Stop loading") { assistant.unload() }
                .buttonStyle(APIActionButtonStyle(tone: .destructive, compact: true))
                .accessibilityIdentifier("api.model.cancel")
        } else if case .ready = assistant.state {
            // Unloading frees the shared runtime, so it goes through the
            // same voice-conflict confirmation as changing the model.
            Button("Unload") {
                store.requestExclusiveOperation("Unloading the API server model") { assistant.unload() }
            }
            .buttonStyle(APIActionButtonStyle(tone: .destructive, compact: true))
            .accessibilityHint("Frees the model's memory. Requests fail until a model loads.")
            .accessibilityIdentifier("api.model.unload")
        }
    }

    @ViewBuilder private var lifecycleButton: some View {
        switch manager.state {
        case .stopped:
            actionButton("Start server", symbol: "play.fill", tone: .primary, identifier: "api.lifecycle") {
                startServer()
            }
        case .starting:
            actionButton("Starting…", symbol: nil, tone: .primary, identifier: "api.lifecycle", showsProgress: true) {}
                .disabled(true)
        case .running:
            actionButton(isStopping ? "Stopping…" : "Stop server",
                         symbol: isStopping ? nil : "stop.fill",
                         tone: .destructive, identifier: "api.lifecycle", showsProgress: isStopping) {
                stopServer()
            }
            .disabled(isStopping)
        case .failed:
            actionButton("Try again", symbol: "arrow.clockwise", tone: .primary, identifier: "api.lifecycle") {
                startServer()
            }
        }
    }

    @ViewBuilder private var restartButton: some View {
        if case .running = manager.state {
            Button {
                Task { await manager.restart() }
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(APIActionButtonStyle(tone: .secondary))
            .disabled(isStopping)
            .accessibilityLabel("Restart server")
            .accessibilityIdentifier("api.restart")
        }
    }

    private func actionButton(_ title: String, symbol: String?, tone: APIActionButtonStyle.Tone, identifier: String,
                              showsProgress: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if showsProgress {
                    ProgressView().controlSize(.small)
                        .tint(tone == .primary ? ODPalette.onSend : ODPalette.text)
                        .accessibilityHidden(true)
                } else if let symbol {
                    Image(systemName: symbol).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                }
                Text(title).font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(APIActionButtonStyle(tone: tone))
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
    }

    // MARK: - Device health

    /// Measured values from the bridge; a dash means unavailable, never a guess.
    private var health: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Device")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    healthCells(divider: true)
                }
                VStack(alignment: .leading, spacing: 12) {
                    healthCells(divider: false)
                }
            }
            .apiCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("api.health")
        }
    }

    @ViewBuilder private func healthCells(divider: Bool) -> some View {
        healthCell("Thermal", store.metrics.thermalLabel, symbol: "thermometer.medium")
        if divider { healthDivider }
        healthCell("App memory", store.metrics.memoryLabel, symbol: "memorychip")
        if divider { healthDivider }
        healthCell("Free storage", store.metrics.diskFreeBytes.map(ODFormat.bytes), symbol: "internaldrive")
    }

    private func healthCell(_ title: String, _ value: String?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(ODPalette.text)
                .lineLimit(1)
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var healthDivider: some View {
        Rectangle()
            .fill(ODPalette.line)
            .frame(width: 1, height: 32)
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
    }

    // MARK: - Connection and setup

    private func connection(port: UInt16) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Connection") {
                Button("Refresh", systemImage: "arrow.clockwise") { manager.refreshAddresses() }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("api.addresses.refresh")
            }

            VStack(alignment: .leading, spacing: 12) {
                if !listenerIsRunning {
                    Label("Setup preview. Start the server before connecting a client.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("api.connection.preview")
                }
                if manager.addresses.isEmpty {
                    Label("No local network address. Connect this iPhone to the same network as your client.",
                          systemImage: "wifi.exclamationmark")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // OpenAI clients want the /v1 base; Ollama and Anthropic
                    // share the bare origin, so it is listed once.
                    ForEach(manager.addresses, id: \.self) { address in
                        addressRow("http://\(address):\(port)/v1", label: "OpenAI")
                        addressRow("http://\(address):\(port)", label: "Ollama · Anthropic")
                    }
                }
                Divider().overlay(ODPalette.line)
                addressRow("http://localhost:\(port)", label: "On this device")

                Divider().overlay(ODPalette.line)
                keyRow

                if let host = manager.addresses.first {
                    Divider().overlay(ODPalette.line)
                    shareConnection(host: host, port: port, identifier: "api.share")
                }
            }
            .apiCard()
        }
    }

    private func shareConnection(host: String, port: UInt16, identifier: String) -> some View {
        ShareLink(item: connectionShareText(host: host, port: port),
                  subject: Text("Token AI local API")) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(ODPalette.accent)
                            .frame(width: 24)
                            .padding(.top, 8)
                            .accessibilityHidden(true)
                        shareConnectionText
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 11) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(ODPalette.accent)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        shareConnectionText
                        Spacer(minLength: 8)
                        Image(systemName: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(APIConnectionPressStyle())
        .accessibilityLabel("Share connection and API key")
        .accessibilityHint("Includes the API key. Share with a trusted device.")
        .accessibilityIdentifier(identifier)
    }

    private var shareConnectionText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Share connection")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ODPalette.text)
            Text("Includes the API key")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addressRow(_ value: String, label: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospaced())
                    .foregroundStyle(ODPalette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(value, feedback: "Address copied")
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.body.weight(.medium))
                    .foregroundStyle(ODPalette.accent)
                    .frame(width: 44, height: 44)
                    .background(ODPalette.input,
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(ODPalette.line, lineWidth: 1)
                    }
            }
            .buttonStyle(APIConnectionPressStyle())
            .accessibilityLabel("Copy \(label) address, \(value)")
            .accessibilityIdentifier("api.copy.address")
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("API key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(revealsKey ? manager.apiKey : String(repeating: "•", count: 12))
                    .font(.footnote.monospaced())
                    .foregroundStyle(ODPalette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .privacySensitive()
            }
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 0) {
                        keyActionsContent(vertical: true)
                    }
                } else {
                    HStack(spacing: 0) {
                        keyActionsContent(vertical: false)
                    }
                }
            }
            .background(ODPalette.input,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(ODPalette.line, lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func keyActionsContent(vertical: Bool) -> some View {
        keyAction(revealsKey ? "Hide" : "Show",
                  symbol: revealsKey ? "eye.slash" : "eye",
                  label: revealsKey ? "Hide API key" : "Reveal API key",
                  identifier: "api.key.reveal") { revealsKey.toggle() }
        if vertical { Divider().overlay(ODPalette.line) }
        else { keyActionDivider }
        keyAction("Copy", symbol: "doc.on.doc", label: "Copy API key",
                  identifier: "api.key.copy") {
            copy(manager.apiKey, feedback: "API key copied")
        }
        if vertical { Divider().overlay(ODPalette.line) }
        else { keyActionDivider }
        keyAction("Rotate", symbol: "arrow.triangle.2.circlepath",
                  label: "Rotate API key", identifier: "api.key.rotate") {
            confirmsKeyRotation = true
        }
    }

    private var keyActionDivider: some View {
        Rectangle()
            .fill(ODPalette.line)
            .frame(width: 1, height: 22)
            .accessibilityHidden(true)
    }

    private func keyAction(_ title: String, symbol: String, label: String,
                           identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(ODPalette.text)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(APIConnectionPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Quick start

    /// Connection recipes built from the actual listener: real address, active
    /// port, served model identifier and API key. The key is masked on screen
    /// unless revealed; Copy always carries the working key.
    private func quickStart(port: UInt16) -> some View {
        let host = manager.addresses.first ?? "localhost"
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Quick start")
            VStack(alignment: .leading, spacing: 12) {
                LocalAPIClientFormatPicker(selection: $format)

                ScrollView(.horizontal) {
                    Text(example(host: host, port: port, key: revealsKey ? manager.apiKey : "<API_KEY>"))
                        .font(.footnote.monospaced())
                        .foregroundStyle(ODPalette.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(12)
                        .accessibilityIdentifier("api.client.example")
                        .privacySensitive()
                }
                .background(ODPalette.input, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Button {
                    copy(example(host: host, port: port, key: manager.apiKey), feedback: "Example copied")
                } label: {
                    Label("Copy with API key", systemImage: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(APIActionButtonStyle(tone: .secondary))
                .accessibilityIdentifier("api.client.example.copy")

                Text(format == .ollama
                     ? "Ollama clients must also send the Authorization bearer header."
                     : "Run it on another device on this network. The selected model on this iPhone answers.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if manager.addresses.isEmpty {
                    Text("These commands use localhost for this device. Connect to Wi-Fi to get an address for another device.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .apiCard()
        }
    }

    private func example(host: String, port: UInt16, key: String) -> String {
        LocalAPIClientSetup(host: host, port: port, modelID: clientSetup.modelID)
            .example(for: format, apiKey: key)
    }

    // MARK: - Configuration

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Configuration")
            VStack(spacing: 0) {
                Button { showPortEditor = true } label: {
                    HStack(spacing: 12) {
                        Text("Port")
                            .font(.body)
                            .foregroundStyle(ODPalette.text)
                        Spacer(minLength: 12)
                        Text(displayedPort)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Port, \(displayedPort)")
                .accessibilityHint("Edit the server port")
                .accessibilityIdentifier("api.port.row")
                .disabled(isStopping || liveActivity == .starting)
                Divider().overlay(ODPalette.line).padding(.leading, 16)
                settingToggle("Keep screen awake", detail: "While the server is running",
                              identifier: "api.keepAwake",
                              isOn: Binding(
                                get: { settings.localAPIKeepScreenAwake },
                                set: {
                                    settings.localAPIKeepScreenAwake = $0
                                    manager.refreshIdleTimerPolicy()
                                }))
                Divider().overlay(ODPalette.line).padding(.leading, 16)
                settingToggle("Load model with server",
                              detail: "Load the selected model when it is already downloaded and the server starts in the foreground",
                              identifier: "api.autoLoad",
                              isOn: Binding(
                                get: { autoLoadModel },
                                set: {
                                    autoLoadModel = $0
                                    if $0 { Task { await manager.autoLoadModelIfEnabled() } }
                                }))
                Divider().overlay(ODPalette.line).padding(.leading, 16)
                // Was hardcoded on and unreachable in the UI. The listener
                // reads it at start, so a running server restarts to apply.
                settingToggle("Nearby devices",
                              detail: "Also accept peer-to-peer Wi‑Fi connections from devices that aren’t on your network",
                              identifier: "api.peerToPeer",
                              isOn: Binding(
                                get: { settings.localAPIIncludePeerToPeer },
                                set: {
                                    settings.localAPIIncludePeerToPeer = $0
                                    if case .running = manager.state { Task { await manager.restart() } }
                                }))
            }
            .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous)
                    .strokeBorder(ODPalette.line, lineWidth: 1)
            }
        }
    }

    private func settingToggle(_ title: String, detail: String, identifier: String,
                               isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .accessibilityIdentifier(identifier)
    }

    private var generation: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Generation")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Tool calling", isOn: $toolCallingEnabled)
                    .accessibilityIdentifier("api.generation.tools")
                Toggle("Parallel tool calls", isOn: $parallelToolCallsEnabled)
                    .disabled(!toolCallingEnabled)
                    .accessibilityIdentifier("api.generation.parallel")
                Toggle("Validate tool arguments", isOn: $strictToolSchemasEnabled)
                    .disabled(!toolCallingEnabled)
                    .accessibilityIdentifier("api.generation.strictSchemas")
                Toggle("Allow model reasoning", isOn: $reasoningEnabled)
                    .accessibilityIdentifier("api.generation.reasoning")
                Stepper("Maximum API output · \(maxOutputTokens) tokens",
                        value: $maxOutputTokens, in: 256...4096, step: 256)
                    .accessibilityIdentifier("api.generation.maxTokens")
                Text("Tool selection has a separate 256-token safety limit. Changes apply to the next request.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .apiCard()
        }
    }

    // MARK: - Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The server stops when the app enters the background and starts again when you return.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("HTTP traffic is not encrypted. Start the server only on a trusted local network.",
                  systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsLink: some View {
        NavigationLink {
            DiagnosticsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Diagnostics")
                        .font(.headline)
                    Text("Review local runtime events and share a report")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .apiCard(padding: 16, radius: ODLayout.panelCorner)
        .accessibilityIdentifier("api.diagnostics")
    }

    // MARK: - Shared pieces

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(minHeight: 28, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionHeader<Accessory: View>(_ title: String,
                                                @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .firstTextBaseline) {
            sectionHeader(title)
            Spacer(minLength: 8)
            accessory()
        }
    }

    private func iconButton(_ symbol: String, label: String, identifier: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ODPalette.accent)
                .frame(width: 40, height: 40)
                .background(ODPalette.input,
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(ODPalette.line, lineWidth: 1)
                }
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(APIConnectionPressStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private func copyButton(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        iconButton("doc.on.doc", label: label, identifier: identifier, action: action)
    }

    private func copy(_ value: String, feedback: String) {
        UIPasteboard.general.string = value
        ToastCenter.shared.success(feedback)
    }

    private func connectionShareText(host: String, port: UInt16) -> String {
        LocalAPIClientSetup(host: host, port: port, modelID: clientSetup.modelID)
            .shareText(apiKey: manager.apiKey)
    }

    // MARK: - Presentation model

    private var statusTitle: String {
        if isStopping { return "Stopping…" }
        switch manager.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .failed: return "Couldn’t start"
        }
    }

    private var statusDetail: String {
        if isStopping { return "Finishing open requests and closing the listener." }
        switch manager.state {
        case .stopped:
            return modelReady ? "Model loaded. Start the server to accept requests."
                : "Clients can’t connect until you start the server."
        case .starting:
            return "Opening the listener on port \(settings.localAPIPort)…"
        case .running(let port):
            return "Accepting requests on port \(port)."
        case .failed:
            return "The listener could not start. Review the message and try again."
        }
    }

    /// VoiceOver/tests read one unambiguous sentence; color is never the only signal.
    private var statusAccessibilityValue: String {
        if isStopping { return "Stopping" }
        switch manager.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting"
        case .running(let port): return "Running on port \(port)"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private var statusColor: Color {
        if isStopping { return .orange }
        switch manager.state {
        case .stopped: return .secondary
        case .starting: return .orange
        case .running: return modelReady ? .green : .orange
        case .failed: return .red
        }
    }

    private var statusSymbol: String {
        if isStopping { return "antenna.radiowaves.left.and.right.slash" }
        switch manager.state {
        case .stopped: return "antenna.radiowaves.left.and.right.slash"
        case .starting: return "antenna.radiowaves.left.and.right"
        case .running: return "antenna.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private var isAnswering: Bool {
        liveActivity == .generating
    }

    private var activityTitle: String {
        if assistant.activeExecutionLocation.isCloud { return "Local model required" }
        switch assistant.state {
        case .generating: return "Model is generating"
        case .ready: return modelReady ? "Waiting for requests" : "Can’t answer yet"
        case .loading: return "Loading the model"
        case .unloaded, .failed: return "Can’t answer yet"
        }
    }

    private var activityDetail: String {
        if assistant.activeExecutionLocation.isCloud { return "Choose a downloaded model for local API requests." }
        switch assistant.state {
        case .generating: return "The shared local runtime is producing a response."
        case .ready: return modelReady ? "Requests are answered by the loaded model."
                : "No model is loaded. Requests fail until a model loads."
        case .loading: return "Requests can be answered once the model finishes loading."
        case .failed: return "The model failed to load. Requests fail until a model loads."
        case .unloaded: return "No model is loaded. Requests fail until a model loads."
        }
    }

    private var modelName: String {
        let name = ODPresentation.modelName(assistant.activeDisplayName, compact: true)
        return name.isEmpty ? "No model selected" : name
    }

    /// Model-scoped wording only. The server's own readiness lives in statusTitle.
    private var modelStatus: String {
        if assistant.activeExecutionLocation.isCloud { return "Unavailable to the local API" }
        if assistant.activeDisplayName.isEmpty { return "Choose a model to serve" }
        switch assistant.state {
        case .unloaded: return "Not loaded"
        case .loading(let detail): return detail.isEmpty ? "Loading…" : "Loading · \(detail)"
        case .ready: return modelReady ? "Model loaded" : "Not loaded"
        case .generating: return "Answering a request"
        case .failed: return "Load failed"
        }
    }

    private var modelIsLoading: Bool {
        switch assistant.state { case .loading: true; default: false }
    }

    private var modelReady: Bool {
        assistant.isModelLoaded
    }

    private var listenerIsRunning: Bool {
        if case .running = manager.state { return true }
        return false
    }

    private var canLoadModel: Bool {
        guard !assistant.activeDisplayName.isEmpty else { return false }
        switch assistant.state {
        case .unloaded, .failed: return true
        case .ready: return !modelReady
        default: return false
        }
    }

    /// The port a client would use right now: the active binding while running,
    /// the saved configuration otherwise. A saved change takes effect through
    /// the restart the port editor performs, so the two never disagree here.
    private var displayedPort: String {
        if case .running(let port) = manager.state { return String(port) }
        return String(settings.localAPIPort)
    }

    // MARK: - Actions

    private func startServer() {
        settings.localAPIEnabled = true
        Task { await manager.start() }
    }

    private func stopServer() {
        settings.localAPIEnabled = false
        isStopping = true
        Task {
            await manager.stop()
            isStopping = false
        }
    }
}

/// Only this small view ticks during runtime work. Idle/offline pages do not
/// continuously animate or imply progress where there is none.
private struct LocalAPIActivityView: View {
    let activity: LocalAPIServerActivity
    let tokenRate: Double
    let isVisible: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: !activity.isWorking || reduceMotion || !isVisible || scenePhase != .active)) { timeline in
            let phase = activity.isWorking && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            HStack(spacing: 12) {
                HStack(alignment: .center, spacing: 3) {
                    ForEach(0..<5, id: \.self) { index in
                        let base = [10.0, 18, 26, 18, 10][index]
                        let pulse = phase == 0 ? 1 : 0.45 + 0.55 * (sin(phase * 12 - Double(index)) + 1) / 2
                        Capsule().fill(tint)
                            .frame(width: 3, height: base * pulse)
                    }
                }
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIVE RUNTIME")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(activity.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ODPalette.text)
                    Text(activity.badge)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if activity == .generating, tokenRate.isFinite, tokenRate > 0 {
                    Text("\(tokenRate, format: .number.precision(.fractionLength(1))) tok/s")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(tint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(ODPalette.input, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live parser")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("api.parser")
    }

    private var accessibilityValue: String {
        let title = String(localized: activity.title)
        let badge = String(localized: activity.badge)
        if activity == .generating, tokenRate.isFinite, tokenRate > 0 {
            return String(localized: "\(title), \(Int(tokenRate.rounded())) tokens per second, \(badge)")
        }
        return "\(title), \(badge)"
    }

    private var tint: Color {
        switch activity {
        case .offline: .secondary
        case .failed: .red
        case .listening, .stopping: .orange
        case .starting, .loading: ODPalette.accent
        case .ready, .generating: .green
        }
    }
}

private struct LocalAPIClientFormatPicker: View {
    @Binding var selection: LocalAPIClientSetup.Format
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            picker.pickerStyle(.menu)
        } else {
            picker.pickerStyle(.segmented)
        }
    }

    private var picker: some View {
        Picker("Client format", selection: $selection) {
            ForEach(LocalAPIClientSetup.Format.allCases) { Text($0.rawValue).tag($0) }
        }
        .accessibilityIdentifier("api.client.format")
    }
}

/// The route reference stays available before starting, without pushing the
/// frequently used server configuration below seventeen endpoint rows.
private struct LocalAPIEndpointsView: View {
    let setup: LocalAPIClientSetup
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Endpoints").font(.headline)
                        Text("\(LocalAPIClientSetup.routes.count) routes · includes classifiers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Endpoints")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("api.endpoints.toggle")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(LocalAPIClientSetup.routes) { route in
                        if route.id == LocalAPIClientSetup.routes.first(where: { $0.group == route.group })?.id {
                            Text(route.group.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                                .accessibilityAddTraits(.isHeader)
                        }
                        HStack(alignment: .center, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(route.method)
                                    .font(.caption2.weight(.bold).monospaced())
                                    .foregroundStyle(route.method == "POST" ? ODPalette.accent : .secondary)
                                Text(route.path)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(ODPalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button {
                                UIPasteboard.general.string = setup.url(for: route)
                                ToastCenter.shared.success("Endpoint copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(APIConnectionPressStyle())
                            .accessibilityLabel("Copy \(route.method) \(route.path) URL")
                            .accessibilityIdentifier("api.endpoint.copy")
                        }
                        .padding(.vertical, 4)
                    }
                    Label("Every route needs the API key as an Authorization bearer or x-api-key header.",
                          systemImage: "key.horizontal")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
            }
        }
        .apiCard()
    }
}

private struct APIActionButtonStyle: ButtonStyle {
    enum Tone: Equatable { case primary, secondary, destructive }

    let tone: Tone
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = compact ? 11 : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(minHeight: compact ? 40 : 48)
            .padding(.horizontal, compact ? 12 : 16)
            .background(fill, in: shape)
            .overlay { shape.strokeBorder(outline, lineWidth: 1) }
            .opacity(isEnabled ? 1 : 0.48)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var fill: Color {
        switch tone {
        case .primary: ODPalette.send
        case .secondary: ODPalette.accentSoft
        case .destructive: ODPalette.input
        }
    }

    private var foreground: Color {
        switch tone {
        case .primary: ODPalette.onSend
        case .secondary: ODPalette.accent
        case .destructive: ODPalette.text
        }
    }

    private var outline: Color {
        switch tone {
        case .primary: ODPalette.send.opacity(0.20)
        case .secondary: ODPalette.accent.opacity(0.12)
        case .destructive: ODPalette.line
        }
    }
}

private struct APIConnectionPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private extension View {
    /// The page's one raised surface: the app's surface color, a hairline and
    /// a continuous corner.
    func apiCard(padding: CGFloat = 16, radius: CGFloat = ODLayout.corner) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(ODPalette.line, lineWidth: 1)
            }
    }
}

// MARK: - Port editing

/// A focused edit surface for one numeric value. Save is enabled only for a
/// valid, changed port; while the listener runs, saving restarts the server so
/// the displayed port never disagrees with the actual binding.
private struct LocalAPIPortSheet: View {
    @ObservedObject private var manager = LocalAPIManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init() {
        _text = State(initialValue: String(AppSettings.shared.localAPIPort))
    }

    private var parsed: Int? { Int(text) }
    private var isValid: Bool { parsed.flatMap { LocalAPIValidation.validPort($0) } != nil }
    private var isChanged: Bool { parsed != nil && parsed != settings.localAPIPort }
    private var canSave: Bool { isValid && isChanged }
    private var isRunning: Bool {
        switch manager.state { case .starting, .running: true; default: false }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $text)
                        .font(.body.monospacedDigit())
                        .keyboardType(.numberPad)
                        .focused($focused)
                        .accessibilityIdentifier("api.port")
                } header: {
                    Text("Server port")
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if !text.isEmpty && !isValid {
                            Text("Enter a port from 1024 through 65535.")
                                .foregroundStyle(.red)
                        } else {
                            Text("Use a port from 1024 through 65535. The current port is \(settings.localAPIPort).")
                        }
                        if isRunning {
                            Text("Saving restarts the server on the new port.")
                        }
                    }
                    .font(.footnote)
                }
            }
            .odNavigationTitle("Port")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(!canSave)
                        .accessibilityIdentifier("api.port.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Hide keyboard", systemImage: "keyboard.chevron.compact.down") { focused = false }
                    Spacer()
                }
            }
            .onAppear { focused = true }
        }
    }

    private func save() {
        guard let port = parsed, LocalAPIValidation.validPort(port) != nil else { return }
        settings.localAPIPort = port
        focused = false
        if isRunning {
            Task { await manager.restart() }
            ToastCenter.shared.success("Port saved", detail: "The server is restarting on port \(port).")
        } else {
            ToastCenter.shared.success("Port saved", detail: "The server will use \(port) when it starts.")
        }
        dismiss()
    }
}
