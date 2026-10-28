import Foundation

/// Reusable task configuration only. Input text and photos remain separate
/// drafts and are never included when saving a classifier.
struct SavedClassifierTask: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let type: ClassifierRequest.Kind
    let instructions: String
    let options: String
    let rubric: String
    let falseCriterion: String
    let trueCriterion: String
}
