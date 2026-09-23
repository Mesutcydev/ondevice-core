import SwiftUI

// Standalone design study. Sample data only; no app services or model downloads.
struct StudyModel: Identifiable {
    let id: String
    let name: String
    let role: String
    let engine: String
    let size: String
    let symbol: String
    static let library = [
        StudyModel(id: "qwen", name: "Qwen 3", role: "Assistant", engine: "MLX", size: "2.4 GB", symbol: "text.bubble"),
        StudyModel(id: "gemma", name: "Gemma 3", role: "Lens", engine: "Core AI", size: "3.2 GB", symbol: "viewfinder"),
        StudyModel(id: "edge", name: "Edge0", role: "Assistant", engine: "Edge0", size: "4.8 GB", symbol: "cpu"),
        StudyModel(id: "llama", name: "Llama 3.2", role: "Assistant", engine: "GGUF", size: "1.9 GB", symbol: "text.bubble"),
        StudyModel(id: "kitten", name: "Kitten TTS", role: "Voice", engine: "ONNX", size: "80 MB", symbol: "waveform"),
        StudyModel(id: "whisper", name: "Whisper", role: "Voice", engine: "whisper.cpp", size: "150 MB", symbol: "mic")
    ]
}

@main struct ModelsConceptsApp: App {
    var body: some Scene {
        WindowGroup {
            StudyRoot()
                .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("large") ? .accessibility1 : .large)
        }
    }
}
struct StudyRoot: View {
    private let variant = ProcessInfo.processInfo.arguments.contains("workspace") ? "workspace" : ProcessInfo.processInfo.arguments.contains("hybrid") ? "hybrid" : ProcessInfo.processInfo.arguments.contains("apple") ? "apple" : ProcessInfo.processInfo.arguments.contains("chatgpt") ? "chatgpt" : "dashboard"
    var body: some View {
        Group {
            if variant == "workspace" { WorkspaceChooser() }
            else if variant == "hybrid" { HybridLibrary() }
            else if variant == "apple" { AppleLibrary() }
            else if variant == "chatgpt" { QuietChooser() }
            else { DashboardLibrary() }
        }
        .accessibilityIdentifier("modelsDesignStudy")
    }
}
struct StudyDetail: View {
    let model: StudyModel
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Role", value: model.role)
                    LabeledContent("Runtime", value: model.engine)
                    LabeledContent("Size", value: model.size)
                }
                Section {
                    Button(selected == model.id ? "Selected" : "Use this model") { selected = model.id; dismiss() }
                } footer: { Text("Design preview with sample data. No model is loaded or downloaded.") }
            }
            .navigationTitle(model.name)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
struct StudyImport: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Import from Files", systemImage: "folder", description: Text("The chosen design will connect this action to the existing file picker and model validation."))
                .navigationTitle("Import a model")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: 01 — Dashboard: dense overview, asymmetric panels, active runtime first.
struct DashboardLibrary: View {
    @State private var selected = "qwen"
    @State private var detail: StudyModel?
    @State private var importing = false
    private let canvas = Color(red: 0.055, green: 0.066, blue: 0.064)
    private let panel = Color(red: 0.105, green: 0.121, blue: 0.114)
    private let lime = Color(red: 0.79, green: 0.91, blue: 0.52)
    private let muted = Color(red: 0.64, green: 0.69, blue: 0.65)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                HStack {
                    Label("ONDEVICE CORE", systemImage: "circle.hexagongrid")
                        .font(.system(.caption, design: .monospaced).weight(.semibold)).tracking(1.5)
                    Spacer()
                    Button { importing = true } label: { Image(systemName: "plus").frame(width: 44, height: 44).background(panel, in: Circle()) }
                        .accessibilityLabel("Import model")
                }.foregroundStyle(muted)
                HStack(alignment: .bottom) {
                    Text("Model\nworkspace").font(.system(size: 38, weight: .semibold)).tracking(-1.7)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("LOCAL", systemImage: "circle.fill").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(lime)
                        Text("6 installed").font(.caption).foregroundStyle(muted)
                    }.padding(.bottom, 7)
                }
                Button { detail = StudyModel.library.first { $0.id == selected } } label: {
                    VStack(alignment: .leading, spacing: 21) {
                        HStack {
                            Text("CURRENT ASSISTANT").font(.system(.caption2, design: .monospaced)).tracking(1.3)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.foregroundStyle(lime)
                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(StudyModel.library.first { $0.id == selected }?.name ?? "Qwen 3").font(.title.bold())
                                Text("MLX  /  2.4 GB").font(.system(.caption, design: .monospaced)).foregroundStyle(muted)
                            }
                            Spacer()
                            Text("Ready").font(.caption.weight(.medium)).foregroundStyle(lime)
                        }
                        HStack(spacing: 3) {
                            ForEach(0..<34, id: \.self) { n in
                                RoundedRectangle(cornerRadius: 1).fill(n < 12 ? lime : Color.white.opacity(0.09)).frame(height: 17)
                            }
                        }.accessibilityLabel("Sample memory usage, 35 percent")
                        HStack { Text("Memory footprint"); Spacer(); Text("2.4 / 6.8 GB") }.font(.caption).foregroundStyle(muted)
                    }.padding(22).background(panel, in: RoundedRectangle(cornerRadius: 22))
                }.buttonStyle(.plain)
                HStack(spacing: 12) {
                    metric("12.5", unit: "GB", title: "Model storage", icon: "internaldrive")
                    metric("4", unit: "", title: "Runtime families", icon: "square.stack.3d.up")
                }
                HStack { Text("Your toolkit").font(.title3.weight(.semibold)); Spacer(); Text("ALL MODELS ↗").font(.system(.caption2, design: .monospaced)).foregroundStyle(muted) }
                HStack(alignment: .top, spacing: 12) {
                    roleTile("Assistant", subtitle: "3 models", icon: "text.bubble", model: StudyModel.library[0])
                    roleTile("Lens", subtitle: "1 model", icon: "viewfinder", model: StudyModel.library[1])
                    roleTile("Voice", subtitle: "2 models", icon: "waveform", model: StudyModel.library[4])
                }
                Button { importing = true } label: {
                    HStack { Image(systemName: "arrow.down.to.line"); Text("Bring your own model"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.subheadline.weight(.medium)).padding(.vertical, 18)
                        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
                }.buttonStyle(.plain)
                Text("DESIGN 01 · SAMPLE LIBRARY").font(.system(.caption2, design: .monospaced)).foregroundStyle(muted)
            }.padding(24)
        }
        .background(canvas).foregroundStyle(Color.white.opacity(0.94)).preferredColorScheme(.dark)
        .sheet(item: $detail) { StudyDetail(model: $0, selected: $selected) }
        .sheet(isPresented: $importing) { StudyImport() }
    }
    private func metric(_ value: String, unit: String, title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: icon).font(.subheadline).foregroundStyle(muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) { Text(value).font(.system(size: 29, weight: .medium, design: .rounded)); Text(unit).font(.caption).foregroundStyle(muted) }
            Text(title).font(.caption).foregroundStyle(muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18).background(panel, in: RoundedRectangle(cornerRadius: 18))
    }
    private func roleTile(_ title: String, subtitle: String, icon: String, model: StudyModel) -> some View {
        Button { detail = model } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title3).foregroundStyle(lime)
                VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)); Text(subtitle).font(.caption2).foregroundStyle(muted) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(panel, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
}

// MARK: 02 — Apple: native navigation, grouped library, familiar disclosure rows.
struct AppleLibrary: View {
    @State private var selected = "qwen"
    @State private var detail: StudyModel?
    @State private var importing = false
    @State private var query = ""
    @State private var destination = "Library"
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Destination", selection: $destination) { Text("Library").tag("Library"); Text("Discover").tag("Discover") }.pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)).listRowBackground(Color.clear)
                }
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "internaldrive.fill").foregroundStyle(.blue).font(.title2)
                        VStack(alignment: .leading, spacing: 4) { Text("On This iPhone").font(.headline); Text("6 models · 12.5 GB").font(.subheadline).foregroundStyle(.secondary) }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }.padding(.vertical, 7)
                }
                ForEach(["Assistant", "Lens", "Voice"], id: \.self) { role in
                    Section(role) {
                        ForEach(StudyModel.library.filter { $0.role == role && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { model in
                            Button { detail = model } label: {
                                HStack(spacing: 13) {
                                    Image(systemName: model.symbol).font(.system(size: 19, weight: .medium)).foregroundStyle(.white)
                                        .frame(width: 40, height: 40).background(role == "Assistant" ? Color.blue : role == "Voice" ? Color.orange : Color.purple, in: RoundedRectangle(cornerRadius: 10))
                                    VStack(alignment: .leading, spacing: 4) { Text(model.name).font(.body).foregroundStyle(.primary); Text(model.engine + " · " + model.size).font(.caption).foregroundStyle(.secondary) }
                                    Spacer()
                                    if selected == model.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue) }
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                }.padding(.vertical, 5)
                            }.tint(.primary)
                        }
                    }
                }
                Section {
                    Button { importing = true } label: { Label("Import from Files", systemImage: "folder.badge.plus") }
                    Label("Downloads", systemImage: "arrow.down.circle")
                } footer: { Text("Design 02 · Sample library. Model files stay on your device.") }
            }
            .navigationTitle("Models")
            .searchable(text: $query, prompt: "Search your library")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { importing = true } label: { Image(systemName: "plus").accessibilityLabel("Import model") } } }
            .sheet(item: $detail) { StudyDetail(model: $0, selected: $selected) }
            .sheet(isPresented: $importing) { StudyImport() }
        }.preferredColorScheme(.light)
    }
}

// MARK: 03 — ChatGPT-inspired: quiet chooser, selection first, bottom search.
struct QuietChooser: View {
    @State private var selected = "qwen"
    @State private var detail: StudyModel?
    @State private var importing = false
    @State private var query = ""
    @State private var role = "All models"
    private let ink = Color(white: 0.12)
    private let paper = Color(red: 0.985, green: 0.981, blue: 0.971)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu { Button("All models") { role = "All models" }; Button("Voice") { role = "Voice" }; Button("Assistant") { role = "Assistant" } } label: {
                    Image(systemName: "line.3.horizontal").font(.title3).frame(width: 44, height: 44)
                }.accessibilityLabel("Model categories")
                Spacer()
                Text("OnDevice").font(.headline)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down").font(.title3).frame(width: 44, height: 44) }.accessibilityLabel("Import model")
            }.padding(.horizontal, 16).padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("A model for\nwhat’s next.").font(.system(size: 38, weight: .medium)).tracking(-1.5)
                        Text("Choose the intelligence you work with.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 32).padding(.bottom, 8)
                    HStack { Text(role).font(.subheadline.weight(.semibold)); Spacer(); Text("On this device").font(.caption).foregroundStyle(.secondary) }
                    VStack(spacing: 27) {
                        ForEach(StudyModel.library.filter { (role == "All models" || $0.role == role) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }) { model in
                            Button { selected = model.id } label: {
                                HStack(alignment: .center, spacing: 16) {
                                    Image(systemName: model.symbol).font(.system(size: 21, weight: .regular)).frame(width: 29)
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) { Text(model.name).font(.body.weight(.medium)); Text(model.engine).font(.caption).foregroundStyle(.secondary) }
                                        Text(model.role == "Voice" ? (model.id == "kitten" ? "Natural speech, read aloud" : "Turn audio into text") : model.id == "gemma" ? "Understand images and scenes" : model.id == "qwen" ? "Everyday writing and thinking" : "Reasoning, code, and complex work")
                                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    if selected == model.id { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .contextMenu { Button("Model details") { detail = model } }
                            .accessibilityAddTraits(selected == model.id ? .isSelected : [])
                        }
                    }
                    Text("Design 03 · Sample library").font(.caption2).foregroundStyle(.tertiary).padding(.top, 4)
                }.padding(.horizontal, 28).padding(.bottom, 25)
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a model", text: $query).font(.body)
                    Button { importing = true } label: { Image(systemName: "plus").font(.title3).frame(width: 36, height: 36).background(Color.black.opacity(0.055), in: Circle()) }.accessibilityLabel("Import model")
                }.padding(14).background(Color.white, in: RoundedRectangle(cornerRadius: 28)).overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(Color.black.opacity(0.12)))
                Text("Private by default. Yours to choose.").font(.caption2).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
        }.foregroundStyle(ink).background(paper).preferredColorScheme(.light)
        .sheet(item: $detail) { StudyDetail(model: $0, selected: $selected) }
        .sheet(isPresented: $importing) { StudyImport() }
    }
}

// MARK: 04 — Dashboard overview inside a native Apple library.
struct HybridLibrary: View {
    @State private var selected = "qwen"
    @State private var detail: StudyModel?
    @State private var importing = false
    @State private var query = ""
    @State private var role = "All"
    @State private var storage = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color { colorScheme == .dark ? Color(red: 0.70, green: 0.82, blue: 0.65) : Color(red: 0.27, green: 0.40, blue: 0.28) }
    private var current: StudyModel { StudyModel.library.first { $0.id == selected } ?? StudyModel.library[0] }
    private var filtered: [StudyModel] {
        StudyModel.library.filter { (role == "All" || $0.role == role) && (query.isEmpty || ($0.name + " " + $0.engine).localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { detail = current } label: {
                        VStack(alignment: .leading, spacing: 17) {
                            HStack {
                                Label("In use", systemImage: "circle.fill").font(.caption.weight(.medium))
                                Spacer()
                                Text("On this iPhone").font(.caption)
                            }.foregroundStyle(Color(red: 0.76, green: 0.85, blue: 0.71))
                            HStack(alignment: .center) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(current.name).font(.title2.weight(.semibold)).foregroundStyle(.white)
                                    Text(current.engine + " · " + current.size).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                            }
                            HStack(spacing: 3) {
                                ForEach(0..<36, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1.5).fill(index < 12 ? Color(red: 0.76, green: 0.85, blue: 0.71) : Color.white.opacity(0.12)).frame(height: 7)
                                }
                            }.accessibilityLabel("Sample memory use, 35 percent")
                            HStack { Text("Memory"); Spacer(); Text("2.4 of 6.8 GB") }.font(.caption).foregroundStyle(.white.opacity(0.7))
                        }.padding(20).background(Color(red: 0.13, green: 0.18, blue: 0.15), in: RoundedRectangle(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                }
                Section {
                    Button { storage = true } label: {
                        HStack(spacing: 0) {
                            statistic("6", label: "Models", symbol: "square.stack")
                            Divider().frame(height: 36)
                            statistic("12.5 GB", label: "Storage", symbol: "internaldrive")
                            Divider().frame(height: 36)
                            statistic("4", label: "Runtimes", symbol: "cpu")
                        }.padding(.vertical, 5)
                    }.buttonStyle(.plain)
                }
                Section {
                    ForEach(filtered) { model in
                        Button { detail = model } label: {
                            HStack(spacing: 13) {
                                Image(systemName: model.symbol)
                                    .font(.system(size: 19, weight: .medium)).foregroundStyle(accent)
                                    .frame(width: 38, height: 38)
                                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.name).font(.body.weight(.medium)).foregroundStyle(.primary)
                                    Text(model.engine + " · " + model.size).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if model.id == selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).accessibilityLabel("Selected") }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5)
                        }.tint(.primary)
                    }
                } header: {
                    HStack {
                        Text("Your library").font(.headline).foregroundStyle(.primary)
                        Spacer()
                        Menu {
                            Picker("Category", selection: $role) {
                                ForEach(["All", "Assistant", "Lens", "Voice"], id: \.self) { Text($0).tag($0) }
                            }
                        } label: { HStack(spacing: 4) { Text(role); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline).foregroundStyle(accent) }
                    }.textCase(nil).padding(.bottom, 5)
                } footer: { Text("Design 04 · Sample library") }
            }
            .listSectionSpacing(16)
            .navigationTitle("Models")
            .searchable(text: $query, prompt: "Search models or runtimes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("Import", systemImage: "plus") }.tint(accent)
                }
            }
            .sheet(item: $detail) { StudyDetail(model: $0, selected: $selected) }
            .sheet(isPresented: $importing) { StudyImport() }
            .sheet(isPresented: $storage) {
                NavigationStack {
                    List {
                        LabeledContent("Installed models", value: "6")
                        LabeledContent("Storage used", value: "12.5 GB")
                        LabeledContent("Runtimes", value: "MLX, GGUF, Core AI, Edge0")
                        Text("Sample data for this design preview.").foregroundStyle(.secondary)
                    }.navigationTitle("Library overview")
                    .toolbar { Button("Done") { storage = false } }
                }.presentationDetents([.medium])
            }
        }
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("dark") ? .dark : .light)
    }
    private func statistic(_ value: String, label: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

// MARK: 05 — Dashboard + ChatGPT: a compact overview and an open chooser.
struct WorkspaceChooser: View {
    @State private var selected = "qwen"
    @State private var query = ""
    @State private var role = "All models"
    @State private var importing = false
    @State private var detail: StudyModel?
    private let dark = ProcessInfo.processInfo.arguments.contains("dark")
    private var ink: Color { dark ? Color(white: 0.94) : Color(white: 0.13) }
    private var paper: Color { dark ? Color(white: 0.065) : Color(red: 0.985, green: 0.981, blue: 0.971) }
    private var muted: Color { dark ? Color(white: 0.64) : Color(white: 0.43) }
    private var current: StudyModel { StudyModel.library.first { $0.id == selected } ?? StudyModel.library[0] }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Menu {
                    Picker("Category", selection: $role) {
                        ForEach(["All models", "Assistant", "Lens", "Voice"], id: \.self) { Text($0).tag($0) }
                    }
                } label: { Image(systemName: "line.3.horizontal").font(.title3).frame(width: 44, height: 44) }
                .accessibilityLabel("Model categories")
                Spacer()
                Text("OnDevice").font(.headline)
                Spacer()
                Button { importing = true } label: { Image(systemName: "square.and.arrow.down").font(.title3).frame(width: 44, height: 44) }
                    .accessibilityLabel("Import model")
            }.padding(.horizontal, 16).padding(.top, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Your models.").font(.largeTitle.weight(.medium)).tracking(-1.2)
                        Spacer()
                        Text("On this device").font(.caption).foregroundStyle(muted)
                    }.padding(.top, 22)
                    Button { detail = current } label: {
                        VStack(alignment: .leading, spacing: 19) {
                            HStack {
                                Label("In use", systemImage: "circle.fill").font(.caption.weight(.medium))
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.subheadline)
                            }.foregroundStyle(Color(red: 0.79, green: 0.88, blue: 0.67))
                            HStack(alignment: .firstTextBaseline) {
                                Text(current.name).font(.title2.weight(.semibold)).foregroundStyle(.white)
                                Spacer()
                                Text(current.engine + " · " + current.size).font(.caption).foregroundStyle(.white.opacity(0.68))
                            }
                            HStack(spacing: 3) {
                                ForEach(0..<38, id: \.self) { index in
                                    RoundedRectangle(cornerRadius: 1).fill(index < 12 ? Color(red: 0.79, green: 0.88, blue: 0.67) : Color.white.opacity(0.12)).frame(height: 6)
                                }
                            }.accessibilityLabel("Sample memory use, 35 percent")
                            HStack { Text("Memory footprint"); Spacer(); Text("2.4 / 6.8 GB") }.font(.caption).foregroundStyle(.white.opacity(0.65))
                        }.padding(20).background(Color(red: 0.13, green: 0.16, blue: 0.135), in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                    HStack(spacing: 0) {
                        summary("6", "models")
                        Spacer()
                        summary("12.5 GB", "on disk")
                        Spacer()
                        summary("4", "runtimes")
                    }.padding(.horizontal, 4)
                    HStack {
                        Text(role).font(.subheadline.weight(.semibold))
                        Spacer()
                        Menu {
                            Picker("Category", selection: $role) {
                                ForEach(["All models", "Assistant", "Lens", "Voice"], id: \.self) { Text($0).tag($0) }
                            }
                        } label: { Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44) }.accessibilityLabel("Filter models")
                    }
                    VStack(spacing: 25) {
                        ForEach(StudyModel.library.filter { (role == "All models" || $0.role == role) && (query.isEmpty || ($0.name + " " + $0.engine).localizedCaseInsensitiveContains(query)) }) { model in
                            Button { selected = model.id } label: {
                                HStack(spacing: 15) {
                                    Image(systemName: model.symbol).font(.system(size: 21)).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(model.name).font(.body.weight(.medium))
                                        Text(model.role + " · " + model.engine + " · " + model.size).font(.caption).foregroundStyle(muted)
                                    }
                                    Spacer(minLength: 0)
                                    if selected == model.id { Image(systemName: "checkmark").font(.body.weight(.semibold)) }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityAddTraits(selected == model.id ? .isSelected : [])
                                .contextMenu { Button("Model details") { detail = model } }
                        }
                    }
                    Text("Design preview · Sample library").font(.caption2).foregroundStyle(muted)
                }.padding(.horizontal, 26).padding(.bottom, 24)
            }
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(muted)
                TextField("Find a model", text: $query)
                Button { importing = true } label: { Image(systemName: "plus").font(.title3).frame(width: 40, height: 40) }.accessibilityLabel("Import model")
            }
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
            .background(dark ? Color(white: 0.12) : .white, in: RoundedRectangle(cornerRadius: 28))
            .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(ink.opacity(0.14)))
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
        }.foregroundStyle(ink).background(paper).preferredColorScheme(dark ? .dark : .light)
        .sheet(item: $detail) { StudyDetail(model: $0, selected: $selected) }
        .sheet(isPresented: $importing) { StudyImport() }
    }
    private func summary(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(muted)
        }
    }
}
