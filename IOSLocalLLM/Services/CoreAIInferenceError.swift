import Foundation

enum CoreAIInferenceError: LocalizedError, Equatable {
    case unavailable(String)
    case modelMissing
    case unsupportedCapability(String)
    case invalidImage(String)
    case generationFailed
    case emptyConversation

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .modelMissing: return "Download a Core AI pack from the Models tab first."
        case .unsupportedCapability(let capability): return "The selected Core AI model does not support \(capability)."
        case .invalidImage(let message): return message
        case .generationFailed: return "Core AI could not complete the local generation."
        case .emptyConversation: return "The request has no user message for Core AI to answer."
        }
    }
}

