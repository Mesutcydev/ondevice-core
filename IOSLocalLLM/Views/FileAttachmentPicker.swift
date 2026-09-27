import SwiftUI
import UniformTypeIdentifiers
import Vision
import ImageIO

// MARK: - FileAttachmentPicker
// UIDocumentPickerViewController wrapped for SwiftUI. Caller passes the
// existing attachments so we can refuse on cap overflow. The picker allows
// multi-select but we trim to the remaining slot count.

struct FileAttachmentPicker: UIViewControllerRepresentable {

    /// Currently attached files — used to compute the remaining slot count.
    let existing: [FileAttachmentService.Attachment]
    /// Called with successfully-decoded attachments and a list of human-
    /// readable error messages (one per failed file).
    let onPick: ([FileAttachmentService.Attachment], [String]) -> Void
    let onCancel: () -> Void
    var onImagePick: (([PickedPhoto]) -> Void)? = nil

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .data admits text files with uncommon extensions (for example
        // .cson). The bounded decoder rejects binary files with a clear
        // error; images take the same chat path as the Photos picker.
        let types: [UTType] = [
            .plainText, .utf8PlainText, .text, .sourceCode, .pdf,
            .json, .xml, .yaml, .commaSeparatedText, .tabSeparatedText,
            .data, .image,
            // Common code types iOS reports as conforming to .sourceCode
            // but they sometimes also report as their own UTI.
            UTType(filenameExtension: "swift") ?? .sourceCode,
            UTType(filenameExtension: "py") ?? .sourceCode,
            UTType(filenameExtension: "md") ?? .plainText,
            UTType(filenameExtension: "ts") ?? .sourceCode,
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(existing: existing, onPick: onPick,
                    onImagePick: onImagePick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let existing: [FileAttachmentService.Attachment]
        let onPick: ([FileAttachmentService.Attachment], [String]) -> Void
        let onImagePick: (([PickedPhoto]) -> Void)?
        let onCancel: () -> Void

        init(existing: [FileAttachmentService.Attachment],
             onPick: @escaping ([FileAttachmentService.Attachment], [String]) -> Void,
             onImagePick: (([PickedPhoto]) -> Void)?,
             onCancel: @escaping () -> Void) {
            self.existing = existing
            self.onPick = onPick
            self.onImagePick = onImagePick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                             didPickDocumentsAt urls: [URL]) {
            let remaining = max(0,
                FileAttachmentService.maxAttachmentsPerSend - existing.count)
            let toRead = Array(urls.prefix(remaining))

            Task { @MainActor in
                var ok: [FileAttachmentService.Attachment] = []
                var images: [PickedPhoto] = []
                var errors: [String] = []
                var running = existing
                for url in toRead {
                    do {
                        if onImagePick != nil,
                           UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                            let (preview, visibleText) = try await Self.readImagePreview(url)
                            guard let image = UIImage(data: preview) else {
                                errors.append("\(url.lastPathComponent): image is unreadable")
                                continue
                            }
                            images.append(PickedPhoto(image: image, ocrText: visibleText))
                            continue
                        }
                        let att = try await FileAttachmentService.read(url)
                        switch FileAttachmentService.canAttach(att, to: running) {
                        case .success:
                            ok.append(att)
                            running.append(att)
                        case .failure(let e):
                            errors.append("\(url.lastPathComponent): \(e.localizedDescription)")
                        }
                    } catch let e as AttachmentError {
                        errors.append("\(url.lastPathComponent): \(e.localizedDescription)")
                    } catch {
                        errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                    }
                }
                if urls.count > remaining {
                    errors.append("Skipped \(urls.count - remaining) — limit is \(FileAttachmentService.maxAttachmentsPerSend) files per message.")
                }
                if !images.isEmpty { self.onImagePick?(images) }
                self.onPick(ok, errors)
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }

        /// Files images follow the same OCR plus visual-grounding path as
        /// Photos images. Decode and recognize text away from the composer;
        /// only a bounded preview returns to the main actor.
        private nonisolated static func readImagePreview(_ url: URL) async throws -> (Data, String) {
            try await Task.detached(priority: .userInitiated) {
                let didStart = url.startAccessingSecurityScopedResource()
                defer { if didStart { url.stopAccessingSecurityScopedResource() } }

                let maxBytes = 32 * 1_024 * 1_024
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
                guard !data.isEmpty, data.count <= maxBytes,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 1_600,
                      ] as CFDictionary) else {
                    throw AttachmentError.decodeFailed("Image is unreadable or over 32 MB")
                }

                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                try? handler.perform([request])
                let visibleText = (request.results ?? [])
                    .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                guard let preview = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82) else {
                    throw AttachmentError.decodeFailed("Image preview could not be created")
                }
                return (preview, visibleText)
            }.value
        }
    }
}
