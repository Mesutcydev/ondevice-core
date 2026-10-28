import Combine
import Foundation

@MainActor
enum CoreAIClassifierHost {
    static let workbench: CoreAIClassifierWorkbench = {
        let runtime = CoreAIInferenceService.shared
        let controller = CoreAIClassifierWorkbench(backend: .init(
            activate: { try await runtime.loadClassifier(id: $0) },
            run: { try await runtime.classify($0) },
            validate: { try await runtime.validateClassifier($0) },
            cancel: { runtime.cancelClassifier() },
            unload: { await runtime.unload() }
        ))
        observation = runtime.$loadedClassifierID.dropFirst().sink { id in
            if id == nil { controller.runtimeDidUnload() }
        }
        return controller
    }()
    private static var observation: AnyCancellable?

    static var models: [ClassifierModelInfo] {
        CoreAIModelStore.shared.installations.filter {
            $0.manifest.capabilities.classification == true || CoreAIZooCatalog.model(forSelectionID: $0.assistantSelectionID)?.category == .classifier
        }.map { ClassifierModelInfo(id: $0.assistantSelectionID, name: $0.manifest.displayName, window: $0.manifest.contextWindow) }
        + ClassifierCatalog.models.filter { ClassifierModelStore.shared.installedIDs.contains($0.selectionID) }.map {
            ClassifierModelInfo(id: $0.selectionID, name: $0.name, window: $0.window, isImage: $0.isImage)
        }
    }
}
