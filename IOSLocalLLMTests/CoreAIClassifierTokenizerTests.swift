import XCTest
@testable import IOSLocalLLM

final class CoreAIClassifierTokenizerTests: XCTestCase {
    func testEmptyAddedTokensAndRankedMerges() throws {
        let tokenizer = try fixture()
        XCTAssertEqual(tokenizer.encode(""), [])
        XCTAssertEqual(tokenizer.encode("ab"), [10])
        XCTAssertEqual(tokenizer.encode("a <mask> b"), [8, 4, 5, 7])
        XCTAssertEqual(tokenizer.encode("<eos>ab"), [1, 10])
    }
    func testByteDistinctUnicodeAndFallback() throws {
        let tokenizer = try fixture()
        XCTAssertEqual(tokenizer.encode("\u{e9}"), [15])
        XCTAssertEqual(tokenizer.encode("e\u{301}"), [16])
        XCTAssertEqual(tokenizer.encode("🙂"), [5] + "🙂".utf8.map { 1_000 + Int32($0) })
    }
    func testRefusesAnUnsupportedNormalizationContract() throws {
        XCTAssertThrowsError(try fixture(replacement: "x"))
    }

    private func fixture(replacement: String = "▁") throws -> CoreAIClassifierTokenizer {
        let bytes = (0..<256).map { "\"\(String(format: "<0x%02X>", $0))\":\(1_000 + $0)" }.joined(separator: ",")
        // Keep canonically equivalent keys in JSON bytes. A Swift [String: Int]
        // would collapse them before the parser runs.
        let json = #"""
        {"model":{"type":"BPE","byte_fallback":true,"fuse_unk":true,"unk_token":"<unk>","ignore_merges":false,
        "vocab":{"<pad>":0,"<eos>":1,"<bos>":2,"<unk>":3,"<mask>":4,"▁":5,"a":6,"b":7,"▁a":8,"ab":9,"▁ab":10,
        "é":11,"e":12,"\u0301":13,"e\u0301":14,"▁é":15,"▁e\u0301":16,\#(bytes)},
        "merges":[["▁","a"],["a","b"],["▁a","b"],["e","\u0301"],["▁","é"],["▁","e\u0301"]]},
        "normalizer":{"type":"Replace","pattern":{"String":" "},"content":"\#(replacement)"},
        "pre_tokenizer":{"type":"Metaspace","replacement":"▁","prepend_scheme":"always","split":true},
        "added_tokens":[{"content":"<mask>","id":4,"normalized":false,"single_word":false,"lstrip":true,"rstrip":false},
        {"content":"<eos>","id":1,"normalized":false,"single_word":false,"lstrip":false,"rstrip":false}]}
        """#
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tokenizer.json")
        try Data(json.utf8).write(to: url)
        return try CoreAIClassifierTokenizer(contentsOf: url)
    }
}
