import Foundation

// MARK: - AssistantRuntimeIdentity
//
// Trusted runtime identity for the active loaded model. Built from catalog
// metadata plus the resolved runtime family — never from the model's own
// self-description, and never from stale conversation state. Injected into
// the existing system context so a local model can answer identity questions
// factually, without claiming to be a cloud service and without every runtime
// claiming to be the 35B.

enum AssistantRuntimeIdentity {

    static let marker = "[Runtime identity]"

    /// Short factual identity block for the active model. Returns nil for
    /// runtimes that should not receive an injected identity.
    static func block(
        for model: AssistantModel,
        loadedEdge0Family: Edge0ModelFamily?
    ) -> String? {
        switch model.runtime {
        case .edge0MLX:
            let family = loadedEdge0Family
                ?? Edge0ModelFamily.resolve(repoID: model.repoID)
            let familyName = family?.displayName ?? "Edge0 native runtime"
            let base: String
            switch family {
            case .qwen35MoE:
                base = "Qwen3.5-MoE"
            case .bailing8B:
                base = "Bailing-Ling hybrid MoE"
            case nil:
                base = "Edge0 native family"
            }
            return "\(marker) Active model: \(model.displayName) · "
                + "base family \(base) · execution local/on-device · "
                + "runtime \(familyName) native Swift/MLX. "
                + "If asked which model or language model you are using, "
                + "state this identity briefly. You are not a cloud service."
        case .mlx:
            return "\(marker) Active model: \(model.displayName) · "
                + "execution local/on-device · runtime MLX. "
                + "If asked which model or language model you are using, "
                + "state this identity briefly. You are not a cloud service."
        case .llamaCpp:
            return "\(marker) Active model: \(model.displayName) · "
                + "execution local/on-device · runtime llama.cpp. "
                + "If asked which model or language model you are using, "
                + "state this identity briefly. You are not a cloud service."
        case .coreAI:
            return "\(marker) Active model: \(model.displayName) · "
                + "execution local/on-device · runtime Apple Core AI. "
                + "If asked which model or language model you are using, "
                + "state this identity briefly. You are not a cloud service."
        }
    }

    /// Appends the identity to the existing system message (never duplicating
    /// one), or prepends a system message when the conversation has none.
    static func injecting(
        into messages: [ChatMessage],
        model: AssistantModel,
        loadedEdge0Family: Edge0ModelFamily?
    ) -> [ChatMessage] {
        guard let block = block(
            for: model, loadedEdge0Family: loadedEdge0Family
        ) else { return messages }
        var result = messages
        if let index = result.firstIndex(where: { $0.role == .system }) {
            var message = result[index]
            guard !message.content.contains(marker) else { return result }
            message.content += message.content.isEmpty ? block : "\n\n" + block
            if let hidden = message.modelContent {
                message.modelContent = hidden.isEmpty
                    ? block : hidden + "\n\n" + block
            }
            result[index] = message
        } else {
            result.insert(
                ChatMessage(role: .system, content: block), at: 0
            )
        }
        return result
    }
}
