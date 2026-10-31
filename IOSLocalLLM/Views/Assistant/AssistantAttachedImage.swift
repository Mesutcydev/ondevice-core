import SwiftUI
import ImageIO

/// A fixed-size, synchronously cached preview keeps a sent image stable as
/// replies stream: the first layout already has the final 72-point thumbnail.
/// Generated images use the same view at a larger `side`.
struct AssistantAttachedImage: View {
    static let side: CGFloat = 72
    let data: Data
    let identifier: String
    let side: CGFloat
    let onAnalyze: () -> Void

    private let preview: UIImage?

    init(data: Data, identifier: String, side: CGFloat = Self.side, onAnalyze: @escaping () -> Void) {
        self.data = data
        self.identifier = identifier
        self.side = side
        self.onAnalyze = onAnalyze
        self.preview = AssistantImagePreviewCache.thumbnail(
            for: data,
            key: "\(identifier)-\(data.count)-\(Int(side))" as NSString,
            maxPixelSize: side * 3
        )
    }

    var body: some View {
        Button(action: onAnalyze) {
            ZStack(alignment: .bottomTrailing) {
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } else {
                    Color.secondary.opacity(0.15)
                        .frame(width: side, height: side)
                }
                Image(systemName: "eye.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.7), in: Circle())
                    .padding(4)
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(width: side, height: side)
        .accessibilityLabel("Attached image")
        .accessibilityHint("Analyze")
        .accessibilityIdentifier("chat.attached-image.\(identifier)")
    }
}

private enum AssistantImagePreviewCache {
    static let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    /// Decode a small thumbnail synchronously so the first rendered frame is
    /// already final. The source is at most 1,600 pixels and cached by key.
    static func thumbnail(for data: Data, key: NSString, maxPixelSize: CGFloat) -> UIImage? {
        if let cached = images.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let thumbnail = UIImage(cgImage: image)
        images.setObject(thumbnail, forKey: key, cost: image.bytesPerRow * image.height)
        return thumbnail
    }
}
