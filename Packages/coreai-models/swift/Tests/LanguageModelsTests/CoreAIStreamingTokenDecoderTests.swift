// Copyright 2026 OnDevice Max contributors.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Testing
import TestUtilities

@testable import CoreAILanguageModels

#if (arch(arm64) || arch(arm64e)) && canImport(CoreAI)
@Suite("Core AI streaming token decoder")
struct CoreAIStreamingTokenDecoderTests {
    @Test("Reconstructs spaces and holds the changing tail")
    func reconstructsFullDecode() {
        let source = "background animated"
        var decoder = CoreAIStreamingTokenDecoder(tokenizer: MockTokenizer())
        let parts = source.utf8.map { decoder.append(Int($0)) }
        #expect(parts.joined() + decoder.finish() == source)
    }

    @Test("Does not leak incomplete UTF-8 or unknown tokens")
    func skipsIncompleteAndUnknown() {
        var decoder = CoreAIStreamingTokenDecoder(tokenizer: MockTokenizer())
        let parts = [0, 0] + Array("é!".utf8).map(Int.init)
        let result = parts.map { decoder.append($0) }.joined() + decoder.finish()
        #expect(result == "é!")
        #expect(!result.contains("<unk>"))
        #expect(!result.contains("\u{FFFD}"))
    }
}
#endif
