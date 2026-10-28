import UIKit
import AppIntents
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

// MARK: - ShareViewController
// Entry point for the iOS share sheet. Accepts images, plain text, URLs, and
// Safari web pages (NSExtensionJavaScriptPreprocessingResultsKey payload) from
// any host app, stages the content into the App Group container, and opens
// the main app's inbox. The user opens Token AI to receive the content;
// Share extensions cannot use UIApplication to force a containing-app launch.
//
// Hand-off URLs:
//   tokenai://share?file=<jpg-name>          → image (lens tab)
//   tokenai://share?text=<percent-encoded>   → text snippet (assistant tab)
//   tokenai://share?url=<percent-encoded>    → URL (assistant tab)
//
// Long text shares (>1500 chars) go through the file-staging path instead of
// the URL — iOS truncates open URLs around 2KB and Safari/Mail share
// selections often exceed that. The query becomes ?textfile=<txt-name>.

final class ShareViewController: UIViewController {

    // App Group identifier — must match the main app's entitlements.
    private static let appGroupID = "group.com.token.TokenAI"
    private static let urlScheme  = "tokenai"

    /// Threshold above which we stash text in a file and hand the
    /// filename to the main app instead of inlining via URL query.
    /// 1500 keeps us safely below the 2048-char open-URL cap iOS
    /// enforces even after percent-encoding overhead.
    private static let inlineTextLimit = 1500
    /// Bound decoded image memory inside the extension. A 2,048² BGRA
    /// thumbnail is ~16 MB versus ~190 MB for a decoded 48 MP source.
    private static let sharedImageMaxPixelSize = 2_048
    /// Failed/abandoned hand-offs should not leave private content in the
    /// shared container indefinitely.
    private static let stagedFileMaxAge: TimeInterval = 24 * 60 * 60

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black.withAlphaComponent(0.4)
        Task { await processSharedItem() }
    }

    // MARK: - Pipeline

    private func processSharedItem() async {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments else {
            await dismiss(success: false, error: "No content to share")
            return
        }

        // Prefer a URL when present so Safari "Share page" reaches Assistant
        // instead of Lens analyzing the preview thumbnail. Image-only shares
        // still take the image path.
        let hasURL = attachments.contains {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }
        if !hasURL {
            for attachment in attachments {
                if attachment.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    do {
                        let imageData = try await loadImageData(from: attachment)
                        let stagedURL = try writeToAppGroup(imageData,
                                                           subdir: "SharedImages",
                                                           ext: "jpg")
                        do {
                            let openURL = try imageOpenURL(for: stagedURL)
                            await saveForMainApp(with: openURL)
                        } catch {
                            try? FileManager.default.removeItem(at: stagedURL)
                            throw error
                        }
                        return
                    } catch {
                        print("[ShareExtension] image load failed: \(error)")
                    }
                }
            }
        }

        for attachment in attachments {
            // Plain text (Notes selection, Messages copy, etc.)
            if attachment.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                if let text = try? await loadText(from: attachment), !text.isEmpty {
                    await handOffText(text)
                    return
                }
            }
            // URLs (Safari link, Mail link, etc.)
            if attachment.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                if let url = try? await loadURL(from: attachment) {
                    await handOffURL(url)
                    return
                }
            }
        }

        await dismiss(success: false, error: "Unsupported content type")
    }

    // MARK: - Loaders

    private func loadImageData(from attachment: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Request the encoded representation instead of `loadItem`, which
            // commonly returns a full-resolution UIImage and eagerly decodes
            // hundreds of MB inside the extension's ~120 MB memory budget.
            attachment.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data else {
                    continuation.resume(throwing: Self.shareError(
                        code: -2,
                        description: "Couldn't read image"
                    ))
                    return
                }
                do {
                    continuation.resume(returning: try Self.downsampledJPEG(from: data))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func downsampledJPEG(from sourceData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else {
            throw shareError(code: -2, description: "Couldn't decode image")
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: sharedImageMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source, 0, options as CFDictionary
        ) else {
            throw shareError(code: -2, description: "Couldn't resize image")
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw shareError(code: -2, description: "Couldn't prepare image")
        }
        CGImageDestinationAddImage(
            destination,
            thumbnail,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw shareError(code: -2, description: "Couldn't encode image")
        }
        return output as Data
    }

    private func loadText(from attachment: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            // NSString's item-provider reading decodes every plain-text
            // representation the old String/Data branches handled.
            _ = attachment.loadObject(ofClass: String.self) { text, error in
                if let text { continuation.resume(returning: text); return }
                continuation.resume(throwing: error ?? NSError(
                    domain: "ShareExtension", code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't read text"]))
            }
        }
    }

    private func loadURL(from attachment: NSItemProvider) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = attachment.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url); return }
                continuation.resume(throwing: error ?? NSError(
                    domain: "ShareExtension", code: -5,
                    userInfo: [NSLocalizedDescriptionKey: "Couldn't read URL"]))
            }
        }
    }

    // MARK: - Hand-off helpers

    private func handOffText(_ text: String) async {
        // Trim and collapse so we don't blow the URL budget on whitespace.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await dismiss(success: false, error: "Empty text")
            return
        }

        do {
            if trimmed.count <= Self.inlineTextLimit {
                let url = try handOffURL(queryName: "text", value: trimmed)
                await saveForMainApp(with: url)
                return
            }
            // Long text stays in the protected App Group staging directory.
            let data = Data(trimmed.utf8)
            let stagedURL = try writeToAppGroup(data,
                                                subdir: "SharedText",
                                                ext: "txt")
            do {
                let openURL = try handOffURL(
                    queryName: "textfile",
                    value: stagedURL.lastPathComponent
                )
                await saveForMainApp(with: openURL)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                throw error
            }
        } catch {
            await dismiss(success: false, error: error.localizedDescription)
        }
    }

    private func handOffURL(_ url: URL) async {
        do {
            let openURL = try handOffURL(queryName: "url", value: url.absoluteString)
            await saveForMainApp(with: openURL)
        } catch {
            await dismiss(success: false, error: "Couldn't save this link.")
        }
    }

    private func imageOpenURL(for stagedURL: URL) throws -> URL {
        try handOffURL(queryName: "file", value: stagedURL.lastPathComponent)
    }

    private func handOffURL(queryName: String, value: String) throws -> URL {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "share"
        components.queryItems = [URLQueryItem(name: queryName, value: value)]
        guard let url = components.url else {
            throw Self.shareError(code: -6, description: "Couldn't create hand-off URL")
        }
        return url
    }

    // MARK: - Storage

    private func writeToAppGroup(_ data: Data,
                                  subdir: String,
                                  ext: String) throws -> URL {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            throw NSError(domain: "ShareExtension", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "App Group container missing. Configure entitlements."
            ])
        }
        let stagingDir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        removeExpiredStagedFiles(in: stagingDir)
        let fileURL = stagingDir.appendingPathComponent("share-\(UUID().uuidString).\(ext)")
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        return fileURL
    }

    private func removeExpiredStagedFiles(in directory: URL) {
        let cutoff = Date().addingTimeInterval(-Self.stagedFileMaxAge)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private static func shareError(code: Int, description: String) -> NSError {
        NSError(
            domain: "ShareExtension",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }

    @MainActor
    private func saveForMainApp(with url: URL) async {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else {
            await dismiss(success: false, error: "Couldn't access Token AI's shared storage.")
            return
        }
        do {
            try ShareInbox.enqueue(url, in: container)
            await dismiss(success: true, error: nil)
        } catch {
            await dismiss(success: false, error: "Couldn't save this item to Token AI.")
        }
    }

    @MainActor
    private func dismiss(success: Bool, error: String?) async {
        let alert = Self.receiptAlert(success: success, error: error) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        present(alert, animated: true)
    }

    /// The review host uses this actual production receipt, including system
    /// Dynamic Type and accessibility, without pretending to perform a share.
    @MainActor
    static func receiptAlert(success: Bool, error: String?, onDone: @escaping () -> Void) -> UIAlertController {
        let alert = UIAlertController(
            title: success ? String(localized: "Saved to Token AI") : String(localized: "Couldn't share"),
            message: success ? String(localized: "Open Token AI to continue with your shared content.") : error,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "Done"), style: .default) { _ in
            onDone()
        })
        return alert
    }
}
