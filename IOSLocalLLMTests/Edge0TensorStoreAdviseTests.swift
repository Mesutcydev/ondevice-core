import Foundation
import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0TensorStoreAdviseTests
//
// Direct coverage for the 5M readahead path (`F_RDADVISE` over expert
// slices). The path only executes when the readahead candidate is enabled,
// so it needs its own tests: range edge cases must issue hints or be
// rejected — never crash. No MLX arrays are involved, so these run on the
// simulator as well as on device.

final class Edge0TensorStoreAdviseTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("advise")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(
        fileSize: Int
    ) throws -> (store: Edge0PreadTensorStore, location: Edge0TensorLocation) {
        let url = directory.appendingPathComponent("model.safetensors")
        try Data(repeating: 0xAB, count: fileSize).write(to: url)
        let store = try Edge0PreadTensorStore(
            path: url.path, shardName: "model.safetensors"
        )
        let location = Edge0TensorLocation(
            name: "language_model.model.layers.0.mlp.switch_mlp.gate.weight",
            shard: "model.safetensors",
            payloadOffset: 4096,
            byteCount: UInt64(fileSize - 4096),
            dtype: .u32,
            shape: [2, (fileSize - 4096) / 8]
        )
        return (store, location)
    }

    func testAdviseSliceIssuesHintsAcrossRanges() throws {
        let (store, location) = try makeStore(fileSize: 1 << 20)

        // A typical expert-row hint (512 KiB, page-aligned).
        XCTAssertTrue(
            store.adviseSlice(location, byteOffset: 0, byteLength: 524_288)
        )
        // Page-unaligned offset and length.
        XCTAssertTrue(
            store.adviseSlice(location, byteOffset: 1234, byteLength: 4095)
        )
        // A single byte at the very end of the tensor.
        XCTAssertTrue(
            store.adviseSlice(
                location,
                byteOffset: location.byteCount - 1,
                byteLength: 1
            )
        )
        // Out-of-range hints are rejected, never issued.
        XCTAssertFalse(
            store.adviseSlice(
                location, byteOffset: location.byteCount, byteLength: 1
            )
        )
        XCTAssertFalse(store.adviseSlice(location, byteOffset: 0, byteLength: 0))
        XCTAssertFalse(
            store.adviseSlice(location, byteOffset: 0, byteLength: Int.max)
        )
    }

    func testAdviseSliceThroughStoreSetSkipsUnknownShards() throws {
        let (_, location) = try makeStore(fileSize: 1 << 20)
        let set = try Edge0TensorStoreSet(
            directory: directory, shardNames: ["model.safetensors"]
        )

        XCTAssertTrue(
            set.adviseSlice(location, byteOffset: 0, byteLength: 65_536)
        )

        let alien = Edge0TensorLocation(
            name: "x", shard: "other.safetensors", payloadOffset: 0,
            byteCount: 16, dtype: .u32, shape: [4]
        )
        XCTAssertFalse(set.adviseSlice(alien, byteOffset: 0, byteLength: 16))
    }

    func testAdviseAfterCloseIsRejectedNotCrash() async throws {
        let (store, location) = try makeStore(fileSize: 1 << 20)
        XCTAssertTrue(store.adviseSlice(location, byteOffset: 0, byteLength: 4096))
        await store.close()
        XCTAssertFalse(store.adviseSlice(location, byteOffset: 0, byteLength: 4096))
    }
}
