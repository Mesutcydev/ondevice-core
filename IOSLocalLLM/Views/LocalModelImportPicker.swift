import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Folders and files use separate pickers: Files treats a folder as navigation
/// when it is mixed with the generic file type in one document picker.
enum LocalModelImportKind: String, Identifiable {
    case folder
    case file
    case modelFiles

    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        // public.directory also covers directory packages (.aimodel) and
        // providers that only expose the parent type.
        case .folder: [.folder, .directory]
        case .file, .modelFiles: [.data]
        }
    }

    /// Directories must open in place (a copy-mode directory pick crashes the
    /// picker). Single files use the system copy, which still works on
    /// re-signed sideload installs where Files refuses open-in-place grants.
    var opensInPlace: Bool { self == .folder }
}

struct LocalModelImportFlow: ViewModifier {
    @Binding var isPresented: Bool
    @State private var showsOptions = false
    @State private var candidates: [URL] = []
    @State private var pickerKind: LocalModelImportKind?
    let onPick: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            // Take over the caller's flag so Documents is scanned once per
            // presentation, before the dialog renders, not on every body pass.
            .onChange(of: isPresented) { _, requested in
                guard requested else { return }
                isPresented = false
                candidates = LocalModelImportService.documentsCandidates()
                showsOptions = true
            }
            .confirmationDialog("Import model", isPresented: $showsOptions, titleVisibility: .visible) {
                ForEach(candidates, id: \.self) { url in
                    Button("“\(url.lastPathComponent)” from On My iPhone") { onPick([url]) }
                }
                Button("Choose folder in Files") { pickerKind = .folder }
                Button("Choose model files in Files") { pickerKind = .modelFiles }
                Button("Choose GGUF file in Files") { pickerKind = .file }
            } message: {
                Text("For an MLX model, open its folder in Files, tap Select All, then Open. You can also pick a folder or one GGUF file. If Files won't open a folder, copy it to On My iPhone › OnDevice Max.")
            }
            .sheet(item: $pickerKind) { kind in
                LocalModelDocumentPicker(kind: kind, onPick: { urls in
                    pickerKind = nil
                    onPick(urls)
                }, onCancel: {
                    pickerKind = nil
                })
            }
    }
}

extension View {
    func localModelImportFlow(isPresented: Binding<Bool>, onPick: @escaping ([URL]) -> Void) -> some View {
        modifier(LocalModelImportFlow(isPresented: isPresented, onPick: onPick))
    }
}

struct LocalModelDocumentPicker: UIViewControllerRepresentable {
    let kind: LocalModelImportKind
    let onPick: ([URL]) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Folders open in place and the import service copies them with file
        // coordination; files arrive as a system copy in tmp.
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: kind.contentTypes,
            asCopy: !kind.opensInPlace
        )
        picker.allowsMultipleSelection = kind == .modelFiles
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { onCancel(); return }
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
