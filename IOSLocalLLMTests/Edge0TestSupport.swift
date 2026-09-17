import Foundation
import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0TestSupport
//
// Shared deterministic fixtures for the Edge0 foundation tests. No model
// weights are committed anywhere; every fixture is generated in a temporary
// directory and removed by the test.

enum Edge0TestFixtures {
    /// Tiny spec with Edge0-8B's quantization (4-bit affine, group 64) and
    /// the same projection layout, scaled down so fixtures are bytes.
    static let tinySpec = Edge0ExpertSpec(
        numExperts: 4,
        firstExpertLayer: 1,
        lastExpertLayer: 2,
        hiddenSize: 128,
        expertIntermediateSize: 64,
        quant: Edge0QuantSpec(bits: 4, groupSize: 64, mode: "affine")
    )

    static func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Edge0Tests-\(name)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    // MARK: Safetensors fixtures

    static func writeSafetensors(
        at url: URL,
        tensors: [(name: String, dtype: String, shape: [Int], payload: Data)]
    ) throws {
        var entries: [String: Any] = [:]
        var offset = 0
        var payload = Data()
        for tensor in tensors {
            entries[tensor.name] = [
                "dtype": tensor.dtype,
                "shape": tensor.shape,
                "data_offsets": [offset, offset + tensor.payload.count],
            ]
            payload.append(tensor.payload)
            offset += tensor.payload.count
        }
        let header = try JSONSerialization.data(
            withJSONObject: entries,
            options: [.sortedKeys]
        )
        try writeRaw(at: url, header: header, payload: payload)
    }

    static func writeRawSafetensors(
        at url: URL,
        headerJSON: String,
        payload: Data
    ) throws {
        try writeRaw(at: url, header: Data(headerJSON.utf8), payload: payload)
    }

    static func writeRaw(at url: URL, header: Data, payload: Data) throws {
        var data = Data()
        var length = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(header)
        data.append(payload)
        try data.write(to: url)
    }

    static func payload(shape: [Int], dtype: Edge0SafetensorsDType) -> Data {
        let count = shape.reduce(1, *) * dtype.byteWidth
        return Data((0..<count).map { UInt8($0 % 251) })
    }

    static func zeroPayload(shape: [Int], dtype: Edge0SafetensorsDType) -> Data {
        Data(count: shape.reduce(1, *) * dtype.byteWidth)
    }

    static func tinyExpertTensors(
        spec: Edge0ExpertSpec,
        layers: [Int],
        omit: Set<String> = [],
        shapeOverrides: [String: [Int]] = [:],
        dtypeOverrides: [String: String] = [:]
    ) -> [(name: String, dtype: String, shape: [Int], payload: Data)] {
        var tensors: [(name: String, dtype: String, shape: [Int], payload: Data)] = []
        for layer in layers {
            for projection in Edge0ExpertProjection.allCases {
                for part in Edge0ExpertTensorPart.allCases {
                    let name = Edge0ExpertTensorNaming.tensorName(
                        layer: layer,
                        projection: projection,
                        part: part
                    )
                    if omit.contains(name) { continue }
                    let shape = shapeOverrides[name]
                        ?? spec.expectedShape(projection: projection, part: part)
                    let dtypeName = dtypeOverrides[name]
                        ?? spec.expectedDType(part: part).rawValue
                    guard let dtype = Edge0SafetensorsDType(rawValue: dtypeName) else {
                        continue
                    }
                    tensors.append(
                        (name, dtypeName, shape, payload(shape: shape, dtype: dtype))
                    )
                }
            }
        }
        return tensors
    }
}

// MARK: - Test helpers

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitOnce() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

enum Edge0TestError: Error {
    case timeout(String)
}

func waitUntil(
    _ description: String,
    timeout: TimeInterval = 3,
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            throw Edge0TestError.timeout(description)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
}
