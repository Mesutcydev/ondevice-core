import SwiftUI
import OnDeviceUI

/// Device is a secondary native workspace. Measurements come from the same host services.
struct NativeDeviceView: View {
    var onOpenMenu: (() -> Void)? = nil
    @ObservedObject private var bridge = ODBridge.shared
    @ObservedObject private var center = ModelDownloadCenter.shared
    @ObservedObject private var assistant = CodingAssistantService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var destination: Destination?
    private enum Destination: String, Identifiable {
        case diagnostics, library, storage, downloads, benchmark, quality, compare, knowledge
        var id: String { rawValue }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Current model") {
                    DisclosureGroup {
                        Text(assistant.activeSelectionID).font(.footnote).textSelection(.enabled)
                            .accessibilityLabel("Model identifier, \(assistant.activeSelectionID)")
                            .accessibilityIdentifier("device.model.identifier")
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(ODPresentation.modelName(assistant.activeDisplayName, compact: true))
                                .font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("\(bridge.store.modelPhase.title) · \(bridge.store.executionLabel ?? "Unavailable")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 4)
                    }
                }
                Section("Runtime") {
                    LabeledContent("App memory footprint", value: bridge.store.metrics.memoryLabel ?? "Unavailable")
                    LabeledContent("Thermal state", value: bridge.store.metrics.thermalLabel ?? "Unavailable")
                }
                Section("Storage") {
                    LabeledContent("Model files", value: ODFormat.bytes(center.totalStorageUsed))
                    LabeledContent("Free device storage", value: bridge.store.metrics.diskFreeBytes.map(ODFormat.bytes) ?? "Unavailable")
                    Button { destination = .library } label: {
                        HStack { Text("Model library and imports"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                    }.foregroundStyle(.primary)
                    Button { destination = .storage } label: {
                        HStack { Text("Manage storage"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                    }.foregroundStyle(.primary)
                    Button { destination = .downloads } label: {
                        HStack { Text("Downloads and model operations"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                    }.foregroundStyle(.primary)
                }
                Section {
                    DisclosureGroup {
                        Button { destination = .diagnostics } label: {
                            HStack { Text("System diagnostics"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                        Button { destination = .benchmark } label: {
                            HStack { Text("Benchmark"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                        Button { destination = .quality } label: {
                            HStack { Text("Quality evaluation"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                        Button { destination = .compare } label: {
                            HStack { Text("Compare models"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                        Button { destination = .knowledge } label: {
                            HStack { Text("Knowledge base"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                        Button { bridge.store.selectedTab = .apiServer } label: {
                            HStack { Text("API server"); Spacer(); Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary) }
                        }.foregroundStyle(.primary)
                    } label: {
                        Text("Advanced tools")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .accessibilityIdentifier("device.advanced")
                }
            }
            .listStyle(.insetGrouped).monospacedDigit()
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Device")
            .navigationBarTitleDisplayMode(onOpenMenu == nil ? .inline : .large)
            .toolbar {
                if let onOpenMenu {
                    ToolbarItem(placement: .topBarLeading) { ODAppMenuButton(action: onOpenMenu).accessibilityIdentifier("navigation.menu") }
                } else {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
            }
            .onAppear { bridge.refresh() }
            .sheet(item: $destination) { destination in
                switch destination {
                case .diagnostics: SystemStatusView()
                case .library: ModelsManagerView()
                case .storage: ModelStorageCleanupView()
                case .downloads: ModelDownloadCenterView()
                case .benchmark: BenchmarkView()
                case .quality: QualityEvalView()
                case .compare: CompareView()
                case .knowledge: KnowledgeBaseView()
                }
            }
        }
    }
}

extension CodingAssistantService {
    var isFailed: Bool {
        if case .failed(let error) = state {
            return !error.localizedCaseInsensitiveContains("cancel")
        }
        return false
    }
}
