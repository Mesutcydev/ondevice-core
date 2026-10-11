import SwiftUI
import OnDeviceUI

nonisolated final class GitHubReviewCredentials: GitHubCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    var fails = false
    func token(for id: UUID) throws -> String? { try lock.withLock { if fails { throw GitHubError.keychain }; return values[id] } }
    func setToken(_ token: String, for id: UUID) throws { try lock.withLock { if fails { throw GitHubError.keychain }; values[id] = token } }
    func deleteAll() throws { try lock.withLock { if fails { throw GitHubError.keychain }; values = [:] } }
    var count: Int { lock.withLock { values.count } }
}

nonisolated final class GitHubReviewHTTPState: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body: String
        var wait = false
        var headers: [String: String] = [:]
    }
    private let lock = NSLock()
    private var handler: (@Sendable (URLRequest) -> Response)?
    private var recorded: [URLRequest] = []
    private var stopped = 0
    func reset(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock { self.handler = handler; recorded = []; stopped = 0 }
    }
    func response(_ request: URLRequest) -> Response {
        var request = request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
            request.httpBody = data
        }
        let handler = lock.withLock { recorded.append(request); return self.handler }
        return handler?(request) ?? .init(status: 404, body: "{}")
    }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var stopCount: Int { lock.withLock { stopped } }
    func stop() { lock.withLock { stopped += 1 } }
}

nonisolated final class GitHubReviewHTTP: URLProtocol, @unchecked Sendable {
    static let state = GitHubReviewHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { ["api.github.com", "github.com"].contains(request.url?.host ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.response(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"].merging(response.headers) { _, new in new })!, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { client?.urlProtocol(self, didLoad: Data(response.body.utf8)) }
        if !response.wait { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { Self.state.stop() }
    static func client() -> GitHubClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubReviewHTTP.self]
        return GitHubClient(configuration: configuration)
    }
    static let head = String(repeating: "a", count: 40)
    static let tree = String(repeating: "b", count: 40)
    static let blob = String(repeating: "c", count: 40)
    static let newSHA = String(repeating: "d", count: 40)

    static func preview(_ request: URLRequest) -> GitHubReviewHTTPState.Response {
        let path = request.url!.path
        if request.httpMethod == "PATCH" { return .init(body: "{\"object\":{\"sha\":\"\(newSHA)\"}}") }
        if request.httpMethod == "POST" { return .init(status: 201, body: "{\"sha\":\"\(newSHA)\"}") }
        if path == "/user" { return .init(body: "{\"id\":123,\"login\":\"preview\"}") }
        if path == "/user/repos" {
            return .init(body: "[{\"id\":1,\"name\":\"project\",\"owner\":{\"login\":\"preview\"},\"default_branch\":\"main\",\"private\":true,\"permissions\":{\"push\":true}},{\"id\":2,\"name\":\"website\",\"owner\":{\"login\":\"preview\"},\"default_branch\":\"main\",\"private\":false}]")
        }
        if path == "/repos/preview/project" { return .init(body: "{\"id\":1,\"name\":\"project\",\"owner\":{\"login\":\"preview\"},\"default_branch\":\"main\",\"private\":true,\"permissions\":{\"push\":true}}") }
        if path.hasSuffix("/branches") { return .init(body: "[{\"name\":\"main\"},{\"name\":\"feature/ui\"}]") }
        if path.contains("/git/ref/") { return .init(body: "{\"object\":{\"sha\":\"\(head)\"}}") }
        if path.contains("/git/commits/") { return .init(body: "{\"sha\":\"\(head)\",\"tree\":{\"sha\":\"\(tree)\"},\"parents\":[{\"sha\":\"\(newSHA)\"}],\"message\":\"Previous commit\"}") }
        if path.contains("/git/trees/") { return .init(body: "{\"sha\":\"\(tree)\",\"tree\":[{\"path\":\"README.md\",\"type\":\"blob\",\"mode\":\"100755\",\"sha\":\"\(blob)\",\"size\":17}],\"truncated\":false}") }
        if path.hasSuffix("/contents/README.md") {
            let content = Data("# Project\nBefore.\n".utf8).base64EncodedString()
            return .init(body: "{\"type\":\"file\",\"size\":17,\"sha\":\"\(blob)\",\"encoding\":\"base64\",\"content\":\"\(content)\"}")
        }
        if path.hasSuffix("/contents") { return .init(body: "[{\"path\":\"README.md\",\"type\":\"file\"}]") }
        if path.hasSuffix("/check-runs") { return .init(body: "{\"check_runs\":[]}") }
        return .init(status: 404, body: "{}")
    }
}

@MainActor
final class GitHubReviewFixture: ObservableObject {
    let connection: GitHubConnectionStore
    let workspace: GitHubWorkspaceService
    let client: GitHubClient
    init() {
        let defaults = UserDefaults(suiteName: "github-review")!
        defaults.removePersistentDomain(forName: "github-review")
        let credentials = GitHubReviewCredentials()
        let args = ProcessInfo.processInfo.arguments
        if !args.contains("-github-disconnected") {
            let account = GitHubAccount(id: UUID(), login: "preview", userID: 123)
            defaults.set(try? JSONEncoder().encode(account), forKey: GitHubConnectionStore.metadataKey)
            try? credentials.setToken("fixture-github-token-only", for: account.id)
        }
        connection = GitHubConnectionStore(defaults: defaults, credentials: credentials)
        GitHubReviewHTTP.state.reset { GitHubReviewHTTP.preview($0) }
        client = GitHubReviewHTTP.client()
        workspace = GitHubWorkspaceService(connection: connection, client: client)
        if args.contains("-github-enabled") { connection.setEnabled(true) }
        if args.contains("-github-selected"), let account = connection.account {
            try? workspace.select(.init(accountID: account.id, owner: "preview", name: "project", branch: "main"))
        }
    }
}

struct GitHubSettingsReview: View {
    @StateObject private var fixture = GitHubReviewFixture()
    var body: some View { NavigationStack { GitHubSettingsView(connection: fixture.connection, client: fixture.client) } }
}

struct GitHubChatReview: View {
    @StateObject private var fixture = GitHubReviewFixture()
    var body: some View { GitHubChatFixture(workspace: fixture.workspace, connection: fixture.connection) }
}

private struct GitHubChatFixture: View {
    @ObservedObject var workspace: GitHubWorkspaceService
    @ObservedObject var connection: GitHubConnectionStore
    @State private var draft = "Keep my repository draft"
    @State private var picker = false
    @State private var settings = false
    @State private var review: GitHubReviewPlan?
    @State private var result = ""
    @FocusState private var focused: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if connection.isEnabled {
                    GitHubRepositoryIndicator(selection: workspace.draft?.selection,
                        changes: workspace.draft?.changes.count ?? 0, isAvailable: workspace.isAvailable,
                        onSelect: { picker = true }, onReview: { Task { review = try? await workspace.review() } })
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("UI fixture · GitHub requests are mocked").font(.caption).foregroundStyle(.secondary)
                        ODAgentLabel()
                        Text("Choose a repository to audit its files. Changes will wait for your review before a commit.")
                        if !result.isEmpty { Text(result).font(.footnote).accessibilityIdentifier("github.fixture.result") }
                    }.padding(ODLayout.pageInset).frame(maxWidth: .infinity, alignment: .leading)
                }
                ODComposer(text: $draft, focus: $focused, attachments: [], isResponding: workspace.isRunning,
                           canSend: true, canStop: true, canAdd: true, canRemove: true,
                           onAdd: {}, onRemove: { _ in }, onSend: { _, _ in }, onStop: { workspace.cancel() })
            }
            .background { ODPageBackground().ignoresSafeArea() }
            .toolbar {
                ToolbarItem(placement: .principal) { Button {} label: { ODModelMenuLabel(displayName: "Qwen3 4B") }.accessibilityIdentifier("chat.modelPicker") }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("GitHub settings") { settings = true }.accessibilityIdentifier("github.fixture.settings")
                        Button("Stage edit") {
                            Task {
                                if case .result(let text) = await workspace.run(name: "write_file", args: ["path": "README.md", "content": "# Project\nAfter review.\n"]) { result = text }
                            }
                        }.accessibilityIdentifier("github.fixture.stage")
                    } label: { Image(systemName: "ellipsis") }.accessibilityIdentifier("github.fixture.menu")
                }
            }
            .sheet(isPresented: $settings) {
                NavigationStack { GitHubSettingsView(connection: connection, client: workspace.client)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { settings = false } } } }
            }
            .sheet(isPresented: $picker) {
                NavigationStack { GitHubRepositoryPicker(workspace: workspace)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { picker = false } } } }
            }
            .sheet(item: $review) { plan in GitHubReviewView(workspace: workspace, plan: plan) { result, _ in self.result = result } }
        }
    }
}
