import Foundation

/// One source for the workspace's copyable connection details. Credentials are
/// supplied only for an explicit Copy/Share action or a revealed preview.
struct LocalAPIClientSetup {
    enum Format: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case anthropic = "Anthropic"
        case ollama = "Ollama"
        var id: String { rawValue }
    }

    struct Route: Identifiable {
        enum Group {
            case discovery, openAI, anthropic, classifiers, ollama

            var title: LocalizedStringResource {
                switch self {
                case .discovery: "Discovery"
                case .openAI: "OpenAI"
                case .anthropic: "Anthropic"
                case .classifiers: "Classifiers"
                case .ollama: "Ollama"
                }
            }
        }
        let group: Group
        let method: String
        let path: String
        var id: String { "\(method) \(path)" }
    }

    let host: String
    let port: UInt16
    let modelID: String

    var origin: String { "http://\(host):\(port)" }
    var openAIBaseURL: String { origin + "/v1" }

    func example(for format: Format, apiKey: String) -> String {
        switch format {
        case .openAI:
            return """
            export OPENAI_BASE_URL=\(Self.shellQuote(openAIBaseURL))
            export OPENAI_API_KEY=\(Self.shellQuote(apiKey))
            curl "$OPENAI_BASE_URL/models" \\
              -H "Authorization: Bearer $OPENAI_API_KEY"
            """
        case .anthropic:
            let body: [String: Any] = [
                "model": modelID.isEmpty ? "MODEL_ID" : modelID,
                "max_tokens": 128,
                "messages": [["role": "user", "content": "Hello"]]
            ]
            let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
            let json = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return """
            curl \(Self.shellQuote(origin + "/v1/messages")) \\
              -H \(Self.shellQuote("x-api-key: " + apiKey)) \\
              -H 'Content-Type: application/json' \\
              -d \(Self.shellQuote(json))
            """
        case .ollama:
            return """
            curl \(Self.shellQuote(origin + "/api/tags")) \\
              -H \(Self.shellQuote("Authorization: Bearer " + apiKey))
            """
        }
    }

    func shareText(apiKey: String) -> String {
        """
        Token AI local API
        OpenAI base URL: \(openAIBaseURL)
        Ollama / Anthropic base URL: \(origin)
        API key: \(apiKey)

        \(example(for: .openAI, apiKey: apiKey))
        """
    }

    func url(for route: Route) -> String {
        guard route.path == "/v1/models/{model}" else { return origin + route.path }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let identifier = modelID.isEmpty ? "MODEL_ID" : modelID
        return origin + "/v1/models/" + (identifier.addingPercentEncoding(withAllowedCharacters: allowed) ?? identifier)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Keep this catalog aligned with the authenticated routes in LocalAPIServer.
    static let routes: [Route] = [
        .init(group: .discovery, method: "GET", path: "/"),
        .init(group: .discovery, method: "GET", path: "/v1"),
        .init(group: .openAI, method: "GET", path: "/v1/models"),
        .init(group: .openAI, method: "GET", path: "/v1/models/{model}"),
        .init(group: .openAI, method: "GET", path: "/v1/aider/config"),
        .init(group: .openAI, method: "POST", path: "/v1/chat/completions"),
        .init(group: .openAI, method: "POST", path: "/v1/responses"),
        .init(group: .anthropic, method: "POST", path: "/v1/messages"),
        .init(group: .classifiers, method: "GET", path: "/v1/classifiers"),
        .init(group: .classifiers, method: "POST", path: "/v1/classifiers/activate"),
        .init(group: .classifiers, method: "POST", path: "/v1/classifications"),
        .init(group: .ollama, method: "GET", path: "/api/tags"),
        .init(group: .ollama, method: "GET", path: "/api/ps"),
        .init(group: .ollama, method: "GET", path: "/api/version"),
        .init(group: .ollama, method: "POST", path: "/api/show"),
        .init(group: .ollama, method: "POST", path: "/api/chat"),
        .init(group: .ollama, method: "POST", path: "/api/generate")
    ]
}

enum LocalAPIServerActivity: Equatable {
    case offline, starting, stopping, listening, loading, ready, generating, failed

    enum Listener { case stopped, starting, running, failed }
    enum Model { case unloaded, loading, ready, generating, failed, remote }

    init(listener: Listener, model: Model, isStopping: Bool = false) {
        if isStopping { self = .stopping; return }
        switch listener {
        case .stopped: self = .offline
        case .starting: self = .starting
        case .failed: self = .failed
        case .running:
            switch model {
            case .unloaded, .remote: self = .listening
            case .loading: self = .loading
            case .ready: self = .ready
            case .generating: self = .generating
            case .failed: self = .failed
            }
        }
    }

    var isWorking: Bool {
        switch self {
        case .starting, .stopping, .loading, .generating: true
        default: false
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .offline: "Offline"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .listening: "Listening"
        case .loading: "Loading model"
        case .ready: "Ready"
        case .generating: "Streaming"
        case .failed: "Needs attention"
        }
    }

    var badge: LocalizedStringResource {
        switch self {
        case .offline: "SERVER STOPPED"
        case .starting: "CONNECTING"
        case .stopping: "CLOSING"
        case .listening: "NO LOCAL MODEL"
        case .loading: "PREPARING"
        case .ready, .generating: "ON DEVICE"
        case .failed: "CHECK STATUS"
        }
    }
}
