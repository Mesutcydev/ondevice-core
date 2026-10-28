import SwiftUI

/// Actual device measurements in a native secondary settings surface.
@MainActor
struct ODSystemView: View {
    @EnvironmentObject private var store: ODStore
    @Environment(\.dismiss) private var dismiss
    @State private var detailModel: ODModel?
    @State private var deferredModelAction: ODAction?

    var body: some View {
        NavigationStack {
            List {
                Section(ODLocalizedString("Current model")) {
                    if let model = store.selectedModel {
                        Button { detailModel = model } label: {
                            HStack(alignment: .top, spacing: ODLayout.labelGap) {
                                Image(systemName: model.kind.symbol)
                                    .font(.title3).foregroundStyle(.secondary)
                                    .frame(minWidth: ODLayout.groupGap, minHeight: 8 * ODLayout.unit).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: ODLayout.unit) {
                                    Text(model.name).foregroundStyle(ODPalette.text)
                                    phaseLabel(model)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, ODLayout.unit)
                            .frame(minHeight: ODLayout.minimumHit)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text("No model selected", bundle: .module).foregroundStyle(.secondary)
                    }
                }
                Section(ODLocalizedString("Runtime")) {
                    LabeledContent(ODLocalizedString("Execution"), value: store.executionLabel ?? "—")
                    LabeledContent(ODLocalizedString("Memory"), value: store.metrics.memoryLabel ?? "—")
                    LabeledContent(ODLocalizedString("Thermal state"), value: store.metrics.thermalLabel ?? "—")
                }
                Section {
                    LabeledContent(ODLocalizedString("Installed models"), value: String(store.models.filter(\.isInstalled).count))
                    LabeledContent(ODLocalizedString("Model files"), value: store.metrics.modelStorageBytes.map(ODFormat.bytes) ?? "—")
                    LabeledContent(ODLocalizedString("Available"), value: store.metrics.diskFreeBytes.map(ODFormat.bytes) ?? "—")
                    LabeledContent(ODLocalizedString("Device capacity"), value: store.metrics.diskTotalBytes.map(ODFormat.bytes) ?? "—")
                    Button(ODLocalizedString("Manage storage"), systemImage: "internaldrive") { store.send(.manageStorage) }
                        .disabled(!store.canPerformActions || !store.capabilities.canManageStorage)
                } header: {
                    Text("Storage", bundle: .module)
                } footer: {
                    Text("A dash means the measurement is unavailable.", bundle: .module)
                }
                Section {
                    Button(ODLocalizedString("Manage models"), systemImage: "cube") {
                        store.selectedTab = .models
                        store.secondaryRoute = nil
                        dismiss()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .odNavigationTitle("Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ODLocalizedString("Done")) { dismiss() }
                }
            }
            .sheet(item: $detailModel, onDismiss: {
                if let action = deferredModelAction {
                    deferredModelAction = nil
                    store.send(action)
                }
            }) { model in
                ODModelDetailView(modelID: model.id) { action in
                    deferredModelAction = action
                    detailModel = nil
                }.environmentObject(store)
            }
        }
    }

    @ViewBuilder private func phaseLabel(_ model: ODModel) -> some View {
        switch store.phase(for: model) {
        case .preparing(let step):
            HStack(spacing: ODLayout.elementGap) {
                ODBrandMark(height: 8, motion: .live)
                Text(odKey: step.isEmpty ? "Preparing" : step).font(.caption).foregroundStyle(.secondary)
            }
        case .ready:
            Label(ODLocalizedString("Ready"), systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Label(ODLocalizedString(key: message), systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
        case .unloaded:
            Text("Not loaded", bundle: .module).font(.caption).foregroundStyle(.secondary)
        }
    }
}
