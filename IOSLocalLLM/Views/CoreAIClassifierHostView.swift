import SwiftUI
import OnDeviceUI

struct CoreAIClassifierHostView: View {
    let onOpenMenu: () -> Void
    var onOpenModels: () -> Void = {}
    @ObservedObject private var models = CoreAIModelStore.shared
    @ObservedObject private var portableModels = ClassifierModelStore.shared
    var body: some View {
        CoreAIClassifierWorkbenchView(controller: CoreAIClassifierHost.workbench,
            models: CoreAIClassifierHost.models, onOpenMenu: onOpenMenu,
            onActivate: {
                ODBridge.shared.store.requestExclusiveOperation("Activating a classifier") {
                    CoreAIClassifierHost.workbench.startActivation()
                }
            }, onRun: {
                ODBridge.shared.store.requestExclusiveOperation("Running a classifier") {
                    CoreAIClassifierHost.workbench.startRun()
                }
            }, onOpenModels: onOpenModels)
    }
}
