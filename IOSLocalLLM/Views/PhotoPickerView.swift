import SwiftUI
import PhotosUI
import Vision
import CoreImage
import ImageIO

// MARK: - PhotoPickerView
// PHPickerViewController wrapper that returns both the picked image
// and any OCR'd text. Callers decide what to do — typically render the
// image in a chat bubble for the user's eye and include the OCR text
// in the prompt for the LLM. Image-as-code (the prior code-block
// behaviour) is what `text` carries; the image itself comes back so
// the chat UI can show the actual photo.

struct PickedPhoto {
    let image: UIImage
    let attachmentData: Data
    let ocrText: String
}

/// One bounded image is used for display and inference. Do the resize before
/// returning from the picker so JPEG work does not block the chat's main actor.
enum AssistantImageEncoder {
    nonisolated static let maximumPixelEdge: CGFloat = 1_600

    nonisolated static func jpeg(_ image: UIImage) -> Data? {
        let raw = image.cgImage.map { CGSize(width: $0.width, height: $0.height) }
            ?? CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let sideways: Bool
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: sideways = true
        default: sideways = false
        }
        let pixels = sideways ? CGSize(width: raw.height, height: raw.width) : raw
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(1, maximumPixelEdge / max(pixels.width, pixels.height))
        let target = CGSize(width: max(1, (pixels.width * scale).rounded()),
                            height: max(1, (pixels.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

struct PhotoPickerView: UIViewControllerRepresentable {
    let onResult: (PickedPhoto) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onResult: (PickedPhoto) -> Void

        init(onResult: @escaping (PickedPhoto) -> Void) {
            self.onResult = onResult
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }

            let onResult = onResult
            result.itemProvider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                guard let data else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let image = UIImage(data: data), let cgImage = image.cgImage,
                          let attachmentData = AssistantImageEncoder.jpeg(image) else { return }
                    Self.runOCR(on: cgImage, with: image, attachmentData: attachmentData, onResult: onResult)
                }
            }
        }

        nonisolated private static func runOCR(on cgImage: CGImage, with image: UIImage,
                                               attachmentData: Data, onResult: @escaping (PickedPhoto) -> Void) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let handler = VNImageRequestHandler(cgImage: cgImage,
                orientation: CGImagePropertyOrientation(image.imageOrientation), options: [:])
            try? handler.perform([request])
            let sorted = (request.results ?? []).sorted {
                if abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.01 {
                    return $0.boundingBox.minY > $1.boundingBox.minY
                }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            let text = sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async {
                onResult(PickedPhoto(image: image, attachmentData: attachmentData, ocrText: text))
            }
        }
    }
}

private extension CGImagePropertyOrientation {
    nonisolated init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
