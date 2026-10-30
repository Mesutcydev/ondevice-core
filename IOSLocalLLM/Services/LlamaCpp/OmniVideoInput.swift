import Foundation
import AVFoundation
import CoreGraphics

/// Where frames, timestamps and soundtrack slices go in an LFM3-Omni video
/// prompt. A port of llama.cpp b11960's mtmd-helper video reader (`read_next`,
/// `soundtrack_slice`), which decodes through ffmpeg and so cannot run on iOS.
enum OmniVideoLayout {
    enum Item: Equatable, Sendable {
        case text(String)
        /// Position in the picked frame list.
        case frame(Int)
        /// Sample range of the mono soundtrack.
        case audio(Range<Int>)
    }

    /// Frames per timestamp group (`MTMD_VIDEO_TEMPLATE_LFM3_OMNI`).
    static let framesPerGroup = 2

    /// The reference processors' picks: `round(linspace(0, sourceFrames - 1, count))`.
    static func frameIndices(sourceFrames: Int, count: Int) -> [Int] {
        guard sourceFrames > 0, count > 0 else { return [] }
        let step = count > 1 ? Double(sourceFrames - 1) / Double(count - 1) : 0
        return (0..<count).map { Int((Double($0) * step).rounded(.toNearestOrEven)) }
    }

    /// `<X.X seconds>` before each group's first frame (the midpoint of the
    /// group's source times), then its frames, then the soundtrack from the
    /// group's first frame to the next group's (the first group starts at 0,
    /// the last one runs to the end).
    static func items(frameIndices: [Int], sourceFPS: Double, sampleRate: Int, soundtrackSamples: Int) -> [Item] {
        guard !frameIndices.isEmpty, sourceFPS > 0 else { return [] }
        let groups = (frameIndices.count + framesPerGroup - 1) / framesPerGroup
        func groupStart(_ group: Int) -> Int {
            let seconds = Double(frameIndices[group * framesPerGroup]) / sourceFPS
            return min(soundtrackSamples, Int((seconds * Double(sampleRate)).rounded(.toNearestOrEven)))
        }
        var items: [Item] = []
        for index in frameIndices.indices {
            if index % framesPerGroup == 0 {
                let last = min(index + framesPerGroup - 1, frameIndices.count - 1)
                let seconds = (Double(frameIndices[index]) / sourceFPS + Double(frameIndices[last]) / sourceFPS) / 2
                items.append(.text(String(format: "<%.1f seconds>", seconds)))
            }
            items.append(.frame(index))
            let groupEnds = index % framesPerGroup == framesPerGroup - 1 || index + 1 == frameIndices.count
            if soundtrackSamples > 0, sampleRate > 0, groupEnds {
                let group = index / framesPerGroup
                let begin = group == 0 ? 0 : groupStart(group)
                let end = group == groups - 1 ? soundtrackSamples : groupStart(group + 1)
                if begin < end { items.append(.audio(begin..<end)) }
            }
        }
        return items
    }
}

enum OmniVideoError: LocalizedError {
    case noVideoTrack, noLength, frameUnreadable

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The file has no video track."
        case .noLength: "The video has no playable length."
        case .frameUnreadable: "A video frame could not be read."
        }
    }
}

/// A decoded clip ready for mtmd: RGB frames at the size mtmd asked for, the
/// mono soundtrack at the audio encoder's rate, and the prompt layout.
struct OmniVideoClip: Sendable {
    struct Probe: Equatable, Sendable {
        let width: Int
        let height: Int
        let fps: Double
        let sourceFrames: Int
        let duration: Double
    }

    let frames: [[UInt8]]
    let width: Int
    let height: Int
    let soundtrack: [Float]
    let items: [OmniVideoLayout.Item]
    let probe: Probe

    var hasSoundtrack: Bool { !soundtrack.isEmpty }

    /// Video size as displayed (track transform applied), frame rate and length.
    static func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw OmniVideoError.noVideoTrack
        }
        let (natural, transform, nominal, minFrame, range, formats) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .timeRange, .formatDescriptions)
        // Match ffprobe, which mtmd-helper sizes frames from: stored pixels
        // (no pixel-aspect stretch) and the stream's frame rate. Unlike
        // ffprobe, keep the rotation so portrait iPhone clips stay upright.
        let stored = formats.first.map { CMVideoFormatDescriptionGetDimensions($0) }
            .map { CGSize(width: Int($0.width), height: Int($0.height)) } ?? natural
        let shown = stored.applying(transform)
        let fps = minFrame.seconds > 0 ? 1 / minFrame.seconds : Double(nominal > 0 ? nominal : 30)
        let duration = range.duration.seconds
        guard duration.isFinite, duration > 0 else {
            throw OmniVideoError.noLength
        }
        return Probe(width: Int(abs(shown.width).rounded()), height: Int(abs(shown.height).rounded()),
                     fps: fps, sourceFrames: max(1, Int(duration * fps)), duration: duration)
    }

    /// Decodes the picked frames (exact times, scaled to `width`×`height`) and
    /// the first audio track as mono floats at `sampleRate`. A clip without
    /// audio, or a model without an audio encoder (`sampleRate` ≤ 0), gets
    /// frames only, as mtmd-helper does.
    static func load(_ url: URL, probe: Probe, frameCount: Int, width: Int, height: Int,
                     sampleRate: Int) async throws -> OmniVideoClip {
        let picks = OmniVideoLayout.frameIndices(sourceFrames: probe.sourceFrames, count: frameCount)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let outWidth = width > 0 ? width : probe.width
        let outHeight = height > 0 ? height : probe.height
        var frames: [[UInt8]] = []
        frames.reserveCapacity(picks.count)
        for pick in picks {
            try Task.checkCancellation()
            let time = CMTime(seconds: Double(pick) / probe.fps, preferredTimescale: 600)
            let image = try await generator.image(at: time).image
            frames.append(try rgb(image, width: outWidth, height: outHeight))
        }
        let soundtrack = sampleRate > 0
            ? try await monoPCM(asset, sampleRate: sampleRate, seconds: Double(probe.sourceFrames) / probe.fps)
            : []
        let items = OmniVideoLayout.items(frameIndices: picks, sourceFPS: probe.fps,
                                          sampleRate: sampleRate, soundtrackSamples: soundtrack.count)
        return OmniVideoClip(frames: frames, width: outWidth, height: outHeight,
                             soundtrack: soundtrack, items: items, probe: probe)
    }

    /// Packed RGB, stretched to the exact size like ffmpeg's `scale=w:h`.
    private static func rgb(_ image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw OmniVideoError.frameUnreadable }
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for pixel in 0..<(width * height) {
            out[pixel * 3] = rgba[pixel * 4]
            out[pixel * 3 + 1] = rgba[pixel * 4 + 1]
            out[pixel * 3 + 2] = rgba[pixel * 4 + 2]
        }
        return out
    }

    private static func monoPCM(_ asset: AVURLAsset, sampleRate: Int, seconds: Double) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let provider = reader.outputProvider(for: output)
        try reader.start()
        let wanted = Int((seconds * Double(sampleRate)).rounded())
        var samples: [Float] = []
        samples.reserveCapacity(wanted)
        while samples.count < wanted, let ready = try await provider.next() {
            try Task.checkCancellation()
            ready.withUnsafeSampleBuffer { buffer in
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
                let length = CMBlockBufferGetDataLength(block)
                var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
                chunk.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                samples.append(contentsOf: chunk)
            }
        }
        reader.cancelReading()
        return Array(samples.prefix(wanted))
    }
}
