import SwiftUI

/// Diffs share the same copy, export, and expanded viewer as other code.
struct DiffView: View {
    let diffText: String
    var body: some View { CodeBlock(language: "diff", code: diffText) }
}
