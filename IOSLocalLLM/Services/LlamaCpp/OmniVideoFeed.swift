import Foundation

#if LFM3_OMNI
/// Hands a decoded clip to mtmd as one lazy video bitmap, in prompt order.
/// Shared by the app's bridge and scripts/tests/omni-video-harness.
final class OmniVideoFeed {
    private let clip: OmniVideoClip
    private var cursor = 0

    init(_ clip: OmniVideoClip) { self.clip = clip }

    /// One lazy bitmap is one video: mtmd wraps its chunks in the model's
    /// video tokens and joins its audio pieces into one soundtrack. The bitmap
    /// reads from this feed, so keep the feed alive until mtmd_tokenize returns.
    func makeBitmap(_ mc: OpaquePointer) -> OpaquePointer? {
        guard let video = mtmd_bitmap_init_lazy(mc, nil, Unmanaged.passUnretained(self).toOpaque(), { _, user, outBitmap, outText in
            guard let user, let outBitmap, let outText else { return -2 }
            return Unmanaged<OmniVideoFeed>.fromOpaque(user).takeUnretainedValue().next(outBitmap, outText)
        }) else { return nil }
        mtmd_bitmap_set_is_video(video, true)
        return video
    }

    /// 0 with one item set, -1 at the end, -2 on failure (mtmd's contract).
    private func next(_ outBitmap: UnsafeMutablePointer<OpaquePointer?>,
                      _ outText: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
        guard cursor < clip.items.count else { return -1 }
        defer { cursor += 1 }
        switch clip.items[cursor] {
        case .text(let text):
            // mtmd frees it with free().
            outText.pointee = strdup(text)
            return outText.pointee == nil ? -2 : 0
        case .frame(let index):
            let frame = clip.frames[index].withUnsafeBufferPointer {
                mtmd_bitmap_init(UInt32(clip.width), UInt32(clip.height), $0.baseAddress)
            }
            guard let frame else { return -2 }
            mtmd_bitmap_set_mergeable(frame, true)
            mtmd_bitmap_set_is_video(frame, true)
            outBitmap.pointee = frame
            return 0
        case .audio(let range):
            let audio = clip.soundtrack[range].withUnsafeBufferPointer {
                mtmd_bitmap_init_from_audio($0.count, $0.baseAddress)
            }
            guard let audio else { return -2 }
            outBitmap.pointee = audio
            return 0
        }
    }
}
#endif
