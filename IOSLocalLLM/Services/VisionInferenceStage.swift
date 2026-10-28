import Foundation

enum VisionInferenceStage: Sendable, Equatable {
    case loadingModel, readingImage, preparingAnswer, writingAnswer
}
