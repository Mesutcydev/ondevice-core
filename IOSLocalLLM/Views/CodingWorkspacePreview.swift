import SwiftUI
import WebKit
import OnDeviceUI

struct CodingWorkspacePreview: View {
    let files: [CodingWorkspaceFile]
    let activePath: String
    var originHost = "preview"
    @State private var viewport = 0
    @State private var console: [String] = []
    @State private var showConsole = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.odWorkspaceVisible) private var workspaceVisible

    private var file: CodingWorkspaceFile? { files.first { $0.path == activePath } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Preview size", selection: $viewport) {
                    Text("Fit").tag(0); Text("Phone").tag(1); Text("Tablet").tag(2)
                }.pickerStyle(.segmented)
                Button { showConsole.toggle() } label: { Image(systemName: "terminal") }
                    .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                    .accessibilityLabel("Preview console").accessibilityIdentifier("coding.preview.console")
            }.padding(.horizontal, ODLayout.pageInset)
            Divider()
            if let file {
                if ["md", "markdown"].contains(file.language) {
                    ScrollView {
                        Text((try? AttributedString(markdown: file.text)) ?? AttributedString(file.text))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ODLayout.pageInset)
                    }.environment(\.openURL, OpenURLAction { _ in .discarded })
                        .accessibilityIdentifier("coding.preview.markdown")
                } else if ["html", "htm"].contains(file.language) {
                    if scenePhase == .active && workspaceVisible {
                    GeometryReader { geometry in
                        let width = viewport == 1 ? 390.0 : viewport == 2 ? 768.0 : geometry.size.width
                        ScrollView(.horizontal) {
                            CodingPreviewWeb(
                                contents: Dictionary(files.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first }),
                                activePath: activePath,
                                originHost: originHost
                            ) { message in
                                console.append(message); if console.count > 50 { console.removeFirst(console.count - 50) }
                            }
                            .frame(width: width, height: geometry.size.height)
                            .frame(minWidth: geometry.size.width)
                            .accessibilityIdentifier("coding.preview.web")
                        }
                    }
                    } else {
                        ContentUnavailableView("Preview paused", systemImage: "pause.circle",
                                               description: Text("Return to this workspace to run the preview."))
                    }
                } else {
                    ContentUnavailableView("Open an HTML or Markdown file", systemImage: "safari",
                                           description: Text("HTML previews can use CSS and JavaScript files already opened in this workspace."))
                }
            }
            if showConsole {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Console").font(.caption.weight(.semibold)); Spacer()
                        Button("Clear") { console = [] }.font(.caption)
                    }
                    ScrollView {
                        Text(console.isEmpty ? String(localized: "No console messages") : console.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("coding.preview.console.text")
                    }
                }.padding(ODLayout.pageInset).frame(height: 180)
                    .accessibilityIdentifier("coding.preview.messages")
            }
            Text("Local preview · network requests are blocked")
                .font(.caption2).foregroundStyle(ODPalette.secondary).padding(8)
        }.background(ODPalette.background).foregroundStyle(ODPalette.text)
    }
}

struct GeneratedHTMLArtifact: Identifiable, Equatable, Sendable {
    let id: UUID
    let html: String

    init(id: UUID = UUID(), html: String) {
        self.id = id
        self.html = html
    }

    var originHost: String { id.uuidString.lowercased() }
    var file: CodingWorkspaceFile {
        CodingWorkspaceFile(path: "index.html", base: nil, text: html, commit: "")
    }

    static func supports(language: String, code: String) -> Bool {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["html", "htm"].contains(language)
            && !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && code.utf8.count <= CodingWorkspaceLimits.fileBytes
    }
}

struct GeneratedHTMLPreview: View {
    let artifact: GeneratedHTMLArtifact
    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var theme
    @State private var mode = 0
    @State private var isRunning = true
    @State private var reloadRevision = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Preview mode", selection: $mode) {
                    Text("Preview").tag(0)
                    Text("Source").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(ODLayout.pageInset)
                .accessibilityIdentifier("response.preview.mode")
                Divider()
                if mode == 0 {
                    if isRunning {
                        CodingWorkspacePreview(files: [artifact.file], activePath: "index.html", originHost: artifact.originHost)
                            .id(reloadRevision)
                    } else {
                        ContentUnavailableView("Preview stopped", systemImage: "pause.circle",
                                               description: Text("Resume or reload to run this generated HTML again."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        CodeBlock(language: "html", code: artifact.html)
                            .padding(ODLayout.pageInset)
                    }
                }
            }
            .background(theme.bg)
            .navigationTitle("HTML preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if mode == 0 {
                        Button {
                            isRunning.toggle()
                        } label: {
                            Image(systemName: isRunning ? "stop" : "play")
                                .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                        }
                        .accessibilityLabel(isRunning ? "Stop preview" : "Resume preview")
                        .accessibilityIdentifier("response.preview.running")
                        Button {
                            reloadRevision += 1
                            isRunning = true
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                        }
                        .accessibilityLabel("Reload preview")
                        .accessibilityIdentifier("response.preview.reload")
                    }
                }
            }
        }
    }
}

enum CodingPreviewContentRules {
    static let identifier = "ondevice.local-preview.network.v1"
    static let json = """
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}
    ]
    """

    static func install(in controller: WKUserContentController, completion: @escaping (Bool) -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            completion(false)
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            if let list {
                controller.add(list)
                completion(true)
                return
            }
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, _ in
                guard let list else {
                    completion(false)
                    return
                }
                controller.add(list)
                completion(true)
            }
        }
    }
}

private struct CodingPreviewWeb: UIViewRepresentable {
    let contents: [String: String]
    let activePath: String
    let originHost: String
    let onConsole: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(originHost: originHost, onConsole: onConsole) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = CodingPreviewScheme(contents: contents, originHost: originHost)
        configuration.setURLSchemeHandler(handler, forURLScheme: "ondevice-code")
        configuration.userContentController.add(context.coordinator, name: "codeConsole")
        let script = """
        (() => {
          const send = (kind, args) => {
            try { window.webkit.messageHandlers.codeConsole.postMessage((kind + ': ' + Array.from(args).map(x => String(x)).join(' ')).slice(0, 1500)); } catch (_) {}
          };
          ['log','warn','error'].forEach(kind => { const original = console[kind]; console[kind] = function(...args) { send(kind, args); original.apply(console, args); }; });
          window.addEventListener('error', event => send('error', [event.message]));
          window.addEventListener('unhandledrejection', event => send('error', [event.reason]));
        })();
        """
        configuration.userContentController.addUserScript(.init(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false; view.backgroundColor = UIColor(ODPalette.background)
        context.coordinator.scheme = handler
        context.coordinator.webView = view
        CodingPreviewContentRules.install(in: configuration.userContentController) { [weak coordinator = context.coordinator] installed in
            guard let coordinator else { return }
            coordinator.protectionReady = installed
            if installed {
                coordinator.loadIfReady()
            } else {
                coordinator.onConsole(String(localized: "Preview protection could not start. Close and reopen the preview."))
            }
        }
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.contents != contents || context.coordinator.activePath != activePath else { return }
        context.coordinator.contents = contents; context.coordinator.activePath = activePath
        context.coordinator.messageCount = 0
        context.coordinator.scheme?.replace(contents)
        context.coordinator.needsLoad = true
        context.coordinator.loadIfReady()
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading(); uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "codeConsole")
        coordinator.webView = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let originHost: String
        let onConsole: (String) -> Void
        weak var webView: WKWebView?
        var scheme: CodingPreviewScheme?
        var contents: [String: String] = [:]
        var activePath = ""
        var messageCount = 0
        var needsLoad = false
        var protectionReady = false
        init(originHost: String, onConsole: @escaping (String) -> Void) {
            self.originHost = originHost
            self.onConsole = onConsole
        }
        func loadIfReady() {
            guard protectionReady, needsLoad, let webView else { return }
            needsLoad = false
            var components = URLComponents(); components.scheme = "ondevice-code"; components.host = originHost; components.path = "/" + activePath
            if let url = components.url { webView.load(URLRequest(url: url)) }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard messageCount <= 200 else { return }
            messageCount += 1
            if messageCount == 201 { onConsole(String(localized: "Console paused after 200 messages. Edit or reload the preview to resume.")) }
            else if let value = message.body as? String { onConsole(String(value.prefix(1_500))) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let local = url?.scheme == "ondevice-code" && url?.host == originHost
            let mainFrame = navigationAction.targetFrame?.isMainFrame == true
            let pathExtension = (url?.path as NSString?)?.pathExtension.lowercased()
            let allowedDocument = !mainFrame || ["html", "htm"].contains(pathExtension ?? "")
            decisionHandler(local && navigationAction.targetFrame != nil && allowedDocument ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onConsole(String(localized: "Preview could not load a local resource."))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            onConsole(String(localized: "Preview stopped after a rendering failure. Reload or reopen it to try again."))
        }
    }
}

/// Only an in-memory project origin is readable. No device files, credentials or network.
nonisolated final class CodingPreviewScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private let originHost: String
    private var contents: [String: String]
    init(contents: [String: String], originHost: String) {
        self.contents = contents
        self.originHost = originHost
    }
    func replace(_ files: [String: String]) { lock.withLock { contents = files } }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == originHost,
              let path = try? GitHubValidation.path(String(url.path.dropFirst())),
              let text = lock.withLock({ contents[path] }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let html = ["html", "htm"].contains(ext)
        let mime = html ? "text/html" : ext == "css" ? "text/css" : ["js", "mjs"].contains(ext) ? "text/javascript" : ext == "svg" ? "image/svg+xml" : "text/plain"
        let data = Data((html ? Self.protectedHTML(text) : text).utf8)
        let headers = [
            "Content-Type": "\(mime); charset=utf-8",
            "Content-Security-Policy": Self.policy,
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)
            ?? URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    static let policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' ondevice-code:; style-src 'unsafe-inline' ondevice-code:; img-src ondevice-code: data: blob:; font-src ondevice-code: data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
    static func protectedHTML(_ text: String) -> String {
        let metadata = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        // Establish the policy before any user markup, including malformed HTML.
        return "<!doctype html><html><head>\(metadata)</head>\(text)</html>"
    }
}
