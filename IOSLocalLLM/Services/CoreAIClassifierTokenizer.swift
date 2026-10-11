import Foundation
import Hub

/// Local encoding for the published Julia/Laya Gemma-style BPE contract.
/// Uses byte-distinct vocabulary keys and scalar/token-ID merges: Swift String
/// equality folds canonically equivalent Unicode spellings, which BPE must not.
/// No network, chat template, BOS/EOS insertion, or private tokenizer assets.
final class CoreAIClassifierTokenizer: Sendable {
    private struct Added: Sendable {
        let scalars: [UInt32]
        let id: Int32
        let lstrip: Bool
        let rstrip: Bool
    }
    private struct Merge: Sendable { let rank: Int; let id: Int32 }
    private struct Candidate: Comparable {
        let rank: Int
        let left: Int
        let right: Int
        let id: Int32
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rank == rhs.rank ? lhs.left < rhs.left : lhs.rank < rhs.rank
        }
    }
    private let single: [UInt32: Int32]
    private let bytes: [Int32?]
    private let merges: [UInt64: Merge]
    private let added: [UInt32: [Added]]
    private static let space: UInt32 = 0x2581

    init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= 64 * 1_024 * 1_024 else { throw CoreAIClassifierError.unsupportedContract }
        // Existing Hub uses yyjson and BinaryDistinctString dictionary keys.
        // Foundation JSONSerialization collapses six keys in this checkpoint.
        let top = try HubApi().configuration(fileURL: url)
        let model: Config = top["model"], normalizer: Config = top["normalizer"], pre: Config = top["pre_tokenizer"]
        guard model.type.string() == "BPE", model.byteFallback.boolean() == true,
              model.unkToken.string() == "<unk>", model.fuseUnk.boolean() == true,
              model.ignoreMerges.boolean() != true,
              let vocab = model.vocab.dictionary(), let pairs = model.merges.array(),
              let tokens = top.addedTokens.array(),
              normalizer.type.string() == "Replace", normalizer.pattern["String"].string() == " ",
              normalizer.content.string() == "▁",
              pre.type.string() == "Metaspace", pre.replacement.string() == "▁",
              pre.prependScheme.string() == "always", pre.split.boolean() == true
        else { throw CoreAIClassifierError.unsupportedContract }

        var ids: [Data: Int32] = [:]
        var scalars: [UInt32: Int32] = [:]
        ids.reserveCapacity(vocab.count)
        for (key, value) in vocab {
            let token = key.string
            guard let number = value.integer(),
                  let id = Int32(exactly: number), id >= 0, id < 256_000
            else { throw CoreAIClassifierError.invalidToken }
            ids[Data(token.utf8)] = id
            if token.unicodeScalars.count == 1, let scalar = token.unicodeScalars.first {
                scalars[scalar.value] = id
            }
        }
        guard ids[Data("<pad>".utf8)] == 0, ids[Data("<eos>".utf8)] == 1,
              ids[Data("<bos>".utf8)] == 2, ids[Data("<unk>".utf8)] == 3,
              ids[Data("<mask>".utf8)] == 4 else { throw CoreAIClassifierError.invalidToken }
        var byteIDs: [Int32?] = []
        for byte in 0..<256 {
            byteIDs.append(ids[Data(String(format: "<0x%02X>", byte).utf8)])
        }
        var rules: [UInt64: Merge] = [:]
        rules.reserveCapacity(pairs.count)
        for (rank, pair) in pairs.enumerated() {
            if rank % 4_096 == 0 { try Task.checkCancellation() }
            guard let parts = pair.array(), parts.count == 2,
                  let a = parts[0].string(), let b = parts[1].string(),
                  let left = ids[Data(a.utf8)], let right = ids[Data(b.utf8)],
                  let result = ids[Data((a + b).utf8)]
            else { throw CoreAIClassifierError.unsupportedContract }
            rules[Self.key(left, right)] = Merge(rank: rank, id: result)
        }
        var added: [UInt32: [Added]] = [:]
        for token in tokens {
            guard let text = token.content.string(),
                  let id = token["id"].integer().flatMap({ Int32(exactly: $0) }),
                  ids[Data(text.utf8)] == id, !text.isEmpty,
                  token.normalized.boolean() == false, token.singleWord.boolean() == false
            else { throw CoreAIClassifierError.unsupportedContract }
            let item = Added(scalars: text.unicodeScalars.map(\.value), id: id,
                             lstrip: token.lstrip.boolean() == true,
                             rstrip: token.rstrip.boolean() == true)
            added[item.scalars[0], default: []].append(item)
        }
        for first in added.keys { added[first]?.sort { $0.scalars.count > $1.scalars.count } }
        self.single = scalars; self.bytes = byteIDs; self.merges = rules; self.added = added
    }

    func encode(_ text: String) -> [Int32] {
        let input = text.unicodeScalars.map(\.value)
        guard !input.isEmpty else { return [] }
        var result: [Int32] = []
        var start = 0, index = 0
        while index < input.count {
            let match = added[input[index]]?.first { token in
                index + token.scalars.count <= input.count &&
                    input[index..<(index + token.scalars.count)].elementsEqual(token.scalars)
            }
            guard let match else { index += 1; continue }
            var end = index
            if match.lstrip {
                while end > start && Self.isWhitespace(input[end - 1]) { end -= 1 }
            }
            appendSegment(input[start..<end], to: &result)
            result.append(match.id)
            index += match.scalars.count
            if match.rstrip {
                while index < input.count && Self.isWhitespace(input[index]) { index += 1 }
            }
            start = index
        }
        appendSegment(input[start...], to: &result)
        return result
    }

    private func appendSegment(_ segment: ArraySlice<UInt32>, to result: inout [Int32]) {
        guard !segment.isEmpty else { return }
        var normalized = segment.map { $0 == 0x20 ? Self.space : $0 }
        if normalized.first != Self.space { normalized.insert(Self.space, at: 0) }
        var start = 0
        for index in normalized.indices.dropFirst() where normalized[index] == Self.space {
            appendWord(normalized[start..<index], to: &result)
            start = index
        }
        appendWord(normalized[start...], to: &result)
    }

    private func appendWord(_ word: ArraySlice<UInt32>, to result: inout [Int32]) {
        var symbols: [Int32] = []
        var unknown = false
        for scalar in word {
            if let id = single[scalar] {
                if unknown { symbols.append(3); unknown = false }
                symbols.append(id)
            }
            else if let value = Unicode.Scalar(scalar) {
                let fallback = String(value).utf8.map { bytes[Int($0)] }
                if fallback.allSatisfy({ $0 != nil }) {
                    if unknown { symbols.append(3); unknown = false }
                    symbols.append(contentsOf: fallback.compactMap { $0 })
                } else { unknown = true }
            }
        }
        if unknown { symbols.append(3) }
        guard symbols.count > 1 else { result.append(contentsOf: symbols); return }
        var next = symbols.indices.map { $0 + 1 < symbols.count ? $0 + 1 : -1 }
        var previous = symbols.indices.map { $0 - 1 }
        var alive = Array(repeating: true, count: symbols.count)
        var heap: [Candidate] = []
        func enqueue(_ left: Int) {
            guard left >= 0, alive[left], next[left] >= 0 else { return }
            let right = next[left]
            guard let rule = merges[Self.key(symbols[left], symbols[right])] else { return }
            heap.append(Candidate(rank: rule.rank, left: left, right: right, id: rule.id))
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard heap[child] < heap[parent] else { break }
                heap.swapAt(child, parent); child = parent
            }
        }
        for index in symbols.indices.dropLast() { enqueue(index) }
        while !heap.isEmpty {
            let best = heap[0], last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var parent = 0
                while parent * 2 + 1 < heap.count {
                    let left = parent * 2 + 1, right = left + 1
                    let child = right < heap.count && heap[right] < heap[left] ? right : left
                    guard heap[child] < heap[parent] else { break }
                    heap.swapAt(child, parent); parent = child
                }
            }
            guard alive[best.left], alive[best.right], next[best.left] == best.right,
                  let rule = merges[Self.key(symbols[best.left], symbols[best.right])],
                  rule.rank == best.rank, rule.id == best.id else { continue }
            symbols[best.left] = best.id
            alive[best.right] = false
            next[best.left] = next[best.right]
            if next[best.right] >= 0 { previous[next[best.right]] = best.left }
            enqueue(previous[best.left]); enqueue(best.left)
        }
        for index in symbols.indices where alive[index] { result.append(symbols[index]) }
    }

    private static func key(_ left: Int32, _ right: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: left)) << 32 | UInt64(UInt32(bitPattern: right))
    }
    private static func isWhitespace(_ scalar: UInt32) -> Bool {
        Unicode.Scalar(scalar)?.properties.isWhitespace == true
    }
}
