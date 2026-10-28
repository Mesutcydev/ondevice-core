import SwiftUI
import OnDeviceUI
import CryptoKit

/// Real workspace views and services, isolated credentials and deterministic HTTP.
@MainActor
final class CodingReviewFixture: ObservableObject {
    let github = GitHubReviewFixture()
    let controller: CodingWorkspaceController
    init() {
        github.connection.setEnabled(true)
        if let account = github.connection.account {
            try? github.workspace.select(.init(accountID: account.id, owner: "preview", name: "project", branch: "main"))
        }
        GitHubReviewHTTP.state.reset { Self.response($0) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodingReview-\(UUID())", isDirectory: true)
        controller = CodingWorkspaceController(workspace: github.workspace,
            vault: CodingWorkspaceVault(root: root, testKey: SymmetricKey(size: .bits256)))
    }
    nonisolated static let files = [
        "README.md": "# Project\n\nA small counter for learning Swift.\n\nRead Sources/Counter.swift, then explore the web preview.\n",
        "Sources/Counter.swift": "import Foundation\n\nstruct Counter {\n    var value = 0\n\n    mutating func increment() {\n        value += 1\n    }\n}\n",
        "index.html": "<!doctype html><html><head><link rel=\"stylesheet\" href=\"styles.css\"></head><body><h1>Project preview</h1><button id=\"counter\">Count: 0</button><script src=\"script.js\"></script></body></html>",
        "styles.css": "body { font-family: system-ui; padding: 24px; background: #f6f5f1; color: #282725; } button { padding: 12px 20px; border-radius: 12px; }",
        "script.js": "let count = 0; document.getElementById('counter').onclick = () => { document.getElementById('counter').textContent = 'Count: ' + ++count; console.log('Counter changed', count); }; console.log('Preview ready'); window.addEventListener('securitypolicyviolation', event => console.warn('Blocked by policy: ' + event.violatedDirective)); fetch('https://example.invalid/preview-network-test').catch(() => {});"
    ]
    nonisolated static func response(_ request: URLRequest) -> GitHubReviewHTTPState.Response {
        let path = request.url!.path
        if path.contains("/git/trees/") {
            let recursive = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "recursive" } == true
            let sub = path.hasSuffix(String(repeating: "e", count: 40))
            var entries: [[String: Any]] = files.keys.sorted().compactMap { file in
                if sub { guard file.hasPrefix("Sources/") else { return nil } }
                else if !recursive && file.contains("/") { return nil }
                return ["path": sub ? String(file.dropFirst(8)) : file, "type": "blob", "mode": "100644", "sha": GitHubReviewHTTP.blob, "size": files[file]!.utf8.count]
            }
            if !sub { entries.append(["path": "Sources", "type": "tree", "mode": "040000", "sha": String(repeating: "e", count: 40)]) }
            return json(["sha": GitHubReviewHTTP.tree, "tree": entries, "truncated": false])
        }
        if let range = path.range(of: "/contents/"), let text = files[String(path[range.upperBound...])] {
            return json(["type": "file", "size": text.utf8.count, "sha": GitHubReviewHTTP.blob, "encoding": "base64", "content": Data(text.utf8).base64EncodedString()])
        }
        return GitHubReviewHTTP.preview(request)
    }
    nonisolated private static func json(_ value: [String: Any]) -> GitHubReviewHTTPState.Response {
        .init(body: String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}

struct CodingWorkspaceReview: View {
    @ObservedObject var store: ODStore
    @StateObject private var fixture = CodingReviewFixture()
    @State private var context = ""
    var body: some View {
        OnDeviceWorkbench(store: store,
            chatContent: AnyView(VStack {
                HStack {
                    ODAppMenuButton { store.conversationsPresented = true }
                    Text("Prepared context").font(.headline); Spacer()
                    Button("Code") { store.selectedTab = .code }
                }.padding()
                TextEditor(text: $context).font(.caption.monospaced()).accessibilityIdentifier("coding.context.receipt")
            }.background(ODPalette.background)),
            settingsContent: AnyView(NavigationStack { GitHubSettingsView(connection: fixture.github.connection, client: fixture.github.client) }),
            codingContent: AnyView(CodingWorkspaceView(workspace: fixture.github.workspace, controller: fixture.controller,
                onOpenMenu: { store.conversationsPresented = true },
                onAsk: { context = $0; store.selectedTab = .chat })))
    }
}
