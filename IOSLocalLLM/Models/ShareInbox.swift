import Foundation

/// Each share is an independent atomic file, so extension writes cannot replace
/// an unread share. Only the containing app removes an item after receiving it.
enum ShareInbox {
    static let directoryName = "ShareInbox"
    static let maximumAge: TimeInterval = 24 * 60 * 60
    private static let maximumBytes = 64 * 1024

    private struct Entry: Codable {
        let createdAt: Date
        let url: URL
    }

    static func enqueue(_ url: URL, in container: URL, now: Date = Date()) throws {
        guard url.scheme == "ondevice-max", url.host == "share" else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        let data = try JSONEncoder().encode(Entry(createdAt: now, url: url))
        guard data.count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Timestamp names preserve order without examining file metadata.
        let name = String(format: "%020.0f", now.timeIntervalSince1970 * 1_000_000)
            + "-" + UUID().uuidString + ".json"
        try data.write(to: directory.appendingPathComponent(name),
                       options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func consumeNext(in container: URL, now: Date = Date()) throws -> URL? {
        let directory = container.appendingPathComponent(directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            // Bound reads even for a corrupt queue entry. Invalid/expired
            // items are removed without exposing user content to diagnostics.
            let handle = try FileHandle(forReadingFrom: file)
            let data: Data
            do {
                data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let entry = data.count <= maximumBytes
                ? try? JSONDecoder().decode(Entry.self, from: data) : nil
            let valid = entry.map {
                $0.url.scheme == "ondevice-max" && $0.url.host == "share"
                    && now.timeIntervalSince($0.createdAt) <= maximumAge
                    && $0.createdAt <= now.addingTimeInterval(60)
            } ?? false
            try FileManager.default.removeItem(at: file)
            if valid { return entry?.url }
        }
        return nil
    }
}
