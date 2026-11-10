import Foundation

/// Projects image-service state into the same library and transfer rows as
/// other model downloaders, without starting or changing a download.
public enum ODImageModelLibrary {
    public static func entry(id: String, name: String, subtitle: String, sizeLabel: String,
                      estimatedMemoryBytes: Int64?, isInstalled: Bool,
                      downloadProgress: Double?, downloadError: String?) -> ODModel {
        let downloading = downloadProgress != nil
        return ODModel(
            id: id, name: name, metadata: subtitle, kind: .image, isInstalled: isInstalled,
            // A transfer can always be abandoned; a failed one keeps its partial
            // files until it is resumed or cancelled.
            availableCommands: isInstalled ? [.details, .delete]
                : downloading ? [.details, .cancelDownload]
                : downloadError == nil ? [.details, .download] : [.details, .download, .cancelDownload],
            downloadStatus: downloading ? "Downloading" : (downloadError == nil ? nil : "Download failed"),
            downloadDetail: downloadError, downloadProgress: downloadProgress,
            estimatedMemoryBytes: estimatedMemoryBytes,
            summary: subtitle, badges: ["Image"], downloadSizeLabel: sizeLabel
        )
    }
}
