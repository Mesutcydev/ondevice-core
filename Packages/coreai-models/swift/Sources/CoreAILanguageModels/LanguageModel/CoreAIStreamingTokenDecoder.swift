// Copyright 2026 OnDevice Max contributors.
//
// Use of this source code is governed by a BSD-3-clause license that can
// be found in the LICENSE file or at https://opensource.org/licenses/BSD-3-Clause

import Foundation
import Tokenizers

/// Emits only text shared by two successive full-prefix decodes. The last
/// decoded token is held until a following token confirms its spelling and
/// spacing; the final tail is emitted at EOS. This avoids relying on a
/// tokenizer's standalone decode of the previous token as the next prefix.
struct CoreAIStreamingTokenDecoder {
    private let tokenizer: any Tokenizer
    private var tokens: [Int] = []
    private var previousDecode = ""
    private var emitted = ""

    init(tokenizer: any Tokenizer) {
        self.tokenizer = tokenizer
    }

    mutating func append(_ token: Int) -> String {
        // Unknown-token placeholders are tokenizer artifacts, not words a
        // user can act on. They must not enter the assistant transcript.
        guard token != tokenizer.unknownTokenId else { return "" }
        tokens.append(token)
        let decoded = tokenizer.decode(tokens: tokens)
        let stable = String(decoded.commonPrefix(with: previousDecode))
        previousDecode = decoded
        return takeUnemittedPrefix(from: stable)
    }

    mutating func finish() -> String {
        takeUnemittedPrefix(from: tokenizer.decode(tokens: tokens))
    }

    private mutating func takeUnemittedPrefix(from decoded: String) -> String {
        guard !decoded.unicodeScalars.contains("\u{FFFD}"),
              decoded.hasPrefix(emitted) else { return "" }
        let delta = String(decoded.dropFirst(emitted.count))
        emitted = decoded
        return delta
    }
}
