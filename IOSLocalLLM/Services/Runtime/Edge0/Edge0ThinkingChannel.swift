import Foundation

// MARK: - Edge0ThinkingChannel
//
// Streaming state for `<think>…</think>` output. The 35B chat template can
// put the opening marker IN THE PROMPT, and the model can emit the markers
// either as special token ids (248068/248069) OR as ordinary text tokens
// (e.g. a literal "</think>" string). Both paths must land in the same
// normalized form: `<think>reasoning</think>answer`, so the app's existing
// thinking presentation, history stripping, and reasoning/final separation
// keep working and no structural marker is rendered as prose.
//
// The type is pure and dependency-free so every marker/chunk case can be
// tested without a model. Display construction always uses the cumulative
// decoded text, which makes it immune to marker splits across chunks.

struct Edge0ThinkingChannel: Equatable {
    enum Marker: Equatable {
        case open
        case close

        var text: String {
            switch self {
            case .open: return "<think>"
            case .close: return "</think>"
            }
        }
    }

    enum Channel: Equatable {
        case reasoning
        case answer
    }

    private(set) var channel: Channel
    private(set) var openInserted: Bool
    private(set) var closeOffset: Int?
    private(set) var reasoningTokens = 0
    private(set) var finalAnswerTokens = 0
    private(set) var endedWhileThinking = false

    private var literalOpenOffset: Int?
    private var literalCloseOffset: Int?

    let openTokenID: Int?
    let closeTokenID: Int?

    static let openMarkerLength = 7   // "<think>"
    static let closeMarkerLength = 8  // "</think>"

    init(promptOpened: Bool, openTokenID: Int?, closeTokenID: Int?) {
        self.channel = promptOpened ? .reasoning : .answer
        self.openInserted = promptOpened
        self.closeOffset = nil
        self.openTokenID = openTokenID
        self.closeTokenID = closeTokenID
    }

    var inThinking: Bool { channel == .reasoning }

    /// Markers the caller should emit before consuming any token. A
    /// prompt-opened thinking section leads the display.
    var initialMarkers: [Marker] {
        openInserted && channel == .reasoning ? [.open] : []
    }

    /// Consume one generated token id. Structural token markers are detected
    /// before any text scanning. `decodedCount` is the current cumulative
    /// decoded character count (marker ids decode to no text).
    @discardableResult
    mutating func consume(tokenID: Int, decodedCount: Int) -> [Marker] {
        if let closeTokenID, tokenID == closeTokenID, channel == .reasoning {
            channel = .answer
            if closeOffset == nil { closeOffset = decodedCount }
            return [.close]
        }
        if let openTokenID, tokenID == openTokenID,
           channel == .answer, !openInserted {
            channel = .reasoning
            openInserted = true
            return [.open]
        }
        if channel == .reasoning {
            reasoningTokens += 1
        } else if channel == .answer {
            finalAnswerTokens += 1
        }
        return []
    }

    /// Build the normalized display for the cumulative decoded text:
    /// canonical `<think>`/`</think>` markers exactly once, literal markers
    /// removed, answer text after the close. Pure with respect to the text;
    /// only marker bookkeeping mutates.
    mutating func normalize(decoded: String) -> String {
        // Literal close text (model emitted "</think>" as text tokens).
        if literalCloseOffset == nil {
            if let range = decoded.range(of: "</think>") {
                let offset = decoded.distance(
                    from: decoded.startIndex, to: range.lowerBound
                )
                if let existing = closeOffset {
                    if offset < existing {
                        closeOffset = offset
                        literalCloseOffset = offset
                    }
                } else {
                    closeOffset = offset
                    literalCloseOffset = offset
                }
                if channel == .reasoning { channel = .answer }
            }
        }
        // Literal open text when the prompt did not open the section.
        if !openInserted, literalOpenOffset == nil {
            if let range = decoded.range(of: "<think>") {
                openInserted = true
                literalOpenOffset = decoded.distance(
                    from: decoded.startIndex, to: range.lowerBound
                )
                if channel == .answer { channel = .reasoning }
            }
        }
        // A close can be known without a text position yet (marker id
        // consumed this step): place it at the current end.
        if channel == .answer, openInserted, closeOffset == nil,
           reasoningTokens > 0 || literalCloseOffset != nil {
            closeOffset = decoded.count
        }

        var dropped: [(offset: Int, length: Int)] = []
        if let offset = literalOpenOffset {
            dropped.append((offset, Self.openMarkerLength))
        }
        if let offset = literalCloseOffset {
            dropped.append((offset, Self.closeMarkerLength))
        }

        let boundary = closeOffset
        var output = openInserted ? Marker.open.text : ""
        var index = 0
        var insertedClose = false
        for character in decoded {
            if let boundary, !insertedClose, index >= boundary {
                output += Marker.close.text
                insertedClose = true
            }
            let isDropped = dropped.contains {
                index >= $0.offset && index < $0.offset + $0.length
            }
            if !isDropped { output.append(character) }
            index += 1
        }
        if boundary != nil, !insertedClose {
            output += Marker.close.text
        }
        return output
    }

    /// Generation end. A still-open reasoning section is closed so the UI can
    /// present it honestly (no final answer) instead of leaking raw reasoning.
    @discardableResult
    mutating func finish(decoded: String) -> String {
        if channel == .reasoning {
            endedWhileThinking = true
            closeOffset = decoded.count
        }
        return normalize(decoded: decoded)
    }
}
