import Foundation

/// Bundled editorial content. Reading it never opens a runtime or connection.
struct UserGuideSection: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let chapters: [UserGuideChapter]
}

struct UserGuideChapter: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let summary: LocalizedStringResource
    let symbol: String
    let steps: [UserGuideStep]
}

struct UserGuideStep: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let path: LocalizedStringResource
    let action: LocalizedStringResource
    let note: LocalizedStringResource
    let visual: UserGuideVisual
}

enum UserGuideVisual {
    case screenshot(asset: String, focus: UserGuideFocus, label: LocalizedStringResource)
    case flow(nodes: [UserGuideFlowNode], code: String?)
    case modelStates
}

struct UserGuideFocus {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct UserGuideFlowNode: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let symbol: String
}

enum UserGuideContent {}
