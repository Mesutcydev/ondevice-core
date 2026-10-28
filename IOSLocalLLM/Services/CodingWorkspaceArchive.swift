import Foundation

/// Original ZIP STORE encoder. Exports only the bounded, explicitly opened text files.
nonisolated enum CodingWorkspaceArchive {
    static func make(files: [CodingWorkspaceFile]) throws -> Data {
        guard !files.isEmpty, files.count <= CodingWorkspaceLimits.files,
              files.reduce(0, { $0 + $1.text.utf8.count }) <= CodingWorkspaceLimits.totalBytes,
              Set(files.map(\.path)).count == files.count else { throw GitHubError.tooLarge }
        var output = Data(), directory = Data()
        for file in files {
            _ = try GitHubValidation.path(file.path)
            let name = Data(file.path.utf8), bytes = Data(file.text.utf8)
            guard bytes.count <= CodingWorkspaceLimits.fileBytes else { throw GitHubError.tooLarge }
            let crc = crc32(bytes), offset = UInt32(output.count)
            output.zipInteger(UInt32(0x04034b50)); output.zipInteger(UInt16(20))
            output.zipInteger(UInt16(0x0800)); output.zipInteger(UInt16(0))
            output.zipInteger(UInt16(0)); output.zipInteger(UInt16(0x0021))
            output.zipInteger(crc); output.zipInteger(UInt32(bytes.count)); output.zipInteger(UInt32(bytes.count))
            output.zipInteger(UInt16(name.count)); output.zipInteger(UInt16(0))
            output.append(name); output.append(bytes)
            directory.zipInteger(UInt32(0x02014b50)); directory.zipInteger(UInt16(0x0314)); directory.zipInteger(UInt16(20))
            directory.zipInteger(UInt16(0x0800)); directory.zipInteger(UInt16(0))
            directory.zipInteger(UInt16(0)); directory.zipInteger(UInt16(0x0021))
            directory.zipInteger(crc); directory.zipInteger(UInt32(bytes.count)); directory.zipInteger(UInt32(bytes.count))
            directory.zipInteger(UInt16(name.count)); directory.zipInteger(UInt16(0)); directory.zipInteger(UInt16(0))
            directory.zipInteger(UInt16(0)); directory.zipInteger(UInt16(0))
            directory.zipInteger(UInt32(file.mode == "100755" ? 0o100755 : 0o100644) << 16)
            directory.zipInteger(offset); directory.append(name)
        }
        let offset = UInt32(output.count)
        output.append(directory)
        output.zipInteger(UInt32(0x06054b50)); output.zipInteger(UInt16(0)); output.zipInteger(UInt16(0))
        output.zipInteger(UInt16(files.count)); output.zipInteger(UInt16(files.count))
        output.zipInteger(UInt32(directory.count)); output.zipInteger(offset); output.zipInteger(UInt16(0))
        return output
    }
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320) }
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func zipInteger<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
