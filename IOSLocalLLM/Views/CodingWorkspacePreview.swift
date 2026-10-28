import SwiftUI
import WebKit
import OnDeviceUI

struct CodingWorkspacePreview: View {
    let files: [CodingWorkspaceFile]
    let activePath: String
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
                            CodingPreviewWeb(files: files, activePath: activePath) { message in
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

private struct CodingPreviewWeb: UIViewRepresentable {
    let files: [CodingWorkspaceFile]
    let activePath: String
    let onConsole: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onConsole: onConsole) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let handler = CodingPreviewScheme(files: files)
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
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let contents = Dictionary(files.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
        guard context.coordinator.contents != contents || context.coordinator.activePath != activePath else { return }
        context.coordinator.contents = contents; context.coordinator.activePath = activePath
        context.coordinator.messageCount = 0
        context.coordinator.scheme?.replace(contents)
        var components = URLComponents(); components.scheme = "ondevice-code"; components.host = "preview"; components.path = "/" + activePath
        if let url = components.url { view.load(URLRequest(url: url)) }
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading(); uiView.navigationDelegate = nil
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "codeConsole")
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onConsole: (String) -> Void
        var scheme: CodingPreviewScheme?
        var contents: [String: String] = [:]
        var activePath = ""
        var messageCount = 0
        init(onConsole: @escaping (String) -> Void) { self.onConsole = onConsole }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard messageCount <= 200 else { return }
            messageCount += 1
            if messageCount == 201 { onConsole(String(localized: "Console paused after 200 messages. Edit or reload the preview to resume.")) }
            else if let value = message.body as? String { onConsole(String(value.prefix(1_500))) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let local = url?.scheme == "ondevice-code" && url?.host == "preview"
            decisionHandler(local && navigationAction.targetFrame != nil ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onConsole(String(localized: "Preview could not load a local resource."))
        }
    }
}

/// Only an in-memory project origin is readable. No device files, credentials or network.
nonisolated final class CodingPreviewScheme: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var contents: [String: String]
    init(files: [CodingWorkspaceFile]) {
        contents = Dictionary(files.map { ($0.path, $0.text) }, uniquingKeysWith: { first, _ in first })
    }
    func replace(_ files: [String: String]) { lock.withLock { contents = files } }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.host == "preview",
              let path = try? GitHubValidation.path(String(url.path.dropFirst())),
              let text = lock.withLock({ contents[path] }) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let html = ["html", "htm"].contains(ext)
        let mime = html ? "text/html" : ext == "css" ? "text/css" : ["js", "mjs"].contains(ext) ? "text/javascript" : ext == "svg" ? "image/svg+xml" : "text/plain"
        let data = Data((html ? Self.protectedHTML(text) : text).utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
    static func protectedHTML(_ text: String) -> String {
        let policy = "default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' ondevice-code:; style-src 'unsafe-inline' ondevice-code:; img-src ondevice-code: data: blob:; font-src ondevice-code: data:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; object-src 'none'"
        let metadata = "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        // Establish the policy before any user markup, including malformed HTML.
        return "<!doctype html><html><head>\(metadata)</head>\(text)</html>"
    }
}
