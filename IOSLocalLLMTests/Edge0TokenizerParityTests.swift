import XCTest
import Tokenizers
@testable import IOSLocalLLM

// MARK: - Edge0TokenizerParityTests
//
// Exact token-ID parity against the real Edge0 tokenizer artifacts:
// plain texts (ASCII, punctuation, code, Unicode, newline), the real chat
// template with generation prompt, and special tokens. No tolerance.

final class Edge0TokenizerParityTests: XCTestCase {

    private struct Special: Decodable, Equatable {
        let token: String
        let id: Int
    }

    private struct Fixture: Decodable {
        let reference_sha: String
        let plain: [String: [Int]]
        let chat_messages: [[String: String]]
        let chat_ids: [Int]
        let chat_text: String
        let special_tokens: [String: Special]
        let special_ids: [String: Int]
    }

    func testTokenizerMatchesUpstreamExactly() async throws {
        let artifacts = ProcessInfo.processInfo.environment["EDGE0_TOKENIZER_DIR"]
            ?? "/tmp/edge0-artifacts"
        let fixtures = ProcessInfo.processInfo.environment["EDGE0_FIXTURE_DIR"]
            ?? "/tmp/edge0-fixtures"
        let fixtureURL = URL(fileURLWithPath: fixtures)
            .appendingPathComponent("tokenizer_fixture.json")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("tokenizer fixture not found at \(fixtureURL.path)")
        }
        guard FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: artifacts)
                .appendingPathComponent("tokenizer.json").path
        ) else {
            throw XCTSkip("tokenizer artifacts not found at \(artifacts)")
        }

        let fixture = try JSONDecoder().decode(
            Fixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        XCTAssertEqual(
            fixture.reference_sha,
            "0700e6532f45e0d0d99e9c588d7d8cd240538ea0"
        )

        let tokenizer = try await Edge0Tokenizer.load(
            from: URL(fileURLWithPath: artifacts)
        )

        // Plain text: exact IDs.
        for (text, expected) in fixture.plain {
            let actual = tokenizer.encode(text)
            XCTAssertEqual(
                actual,
                expected,
                "token IDs for \(text.debugDescription)"
            )
        }

        // Chat template with generation prompt: exact IDs.
        let chatIDs = try tokenizer.applyChatTemplate(
            messages: fixture.chat_messages,
            templateDirectory: URL(fileURLWithPath: artifacts)
        )
        XCTAssertEqual(chatIDs, fixture.chat_ids, "chat template token IDs")

        // Special tokens.
        XCTAssertEqual(
            fixture.special_tokens["bos_token"],
            Special(token: "<|startoftext|>", id: 156_891)
        )
        XCTAssertEqual(
            fixture.special_tokens["eos_token"],
            Special(token: "<|role_end|>", id: 156_895)
        )
        XCTAssertEqual(
            fixture.special_tokens["pad_token"],
            Special(token: "<|endoftext|>", id: 156_892)
        )
        XCTAssertEqual(tokenizer.convertTokenToId("<|startoftext|>"), 156_891)
        XCTAssertEqual(tokenizer.convertTokenToId("<|endoftext|>"), 156_892)
        XCTAssertEqual(tokenizer.convertTokenToId("<|role_end|>"), 156_895)

        print("[Edge0 tokenizer] plain texts=\(fixture.plain.count) chat_ids=\(chatIDs.count) all exact")
    }
}
