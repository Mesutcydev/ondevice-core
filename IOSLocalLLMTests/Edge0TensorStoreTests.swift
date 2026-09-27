import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0TensorStoreTests

final class Edge0TensorStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("store")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPreadReturnsExactBytesForRange() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = Edge0TestFixtures.payload(shape: [64], dtype: .u32)
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [64], payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }
        let bytes = try file.read(
            offset: location.payloadOffset,
            count: Int(location.byteCount)
        )
        XCTAssertEqual(bytes, payload)

        // Exact sub-range read.
        let head = try file.read(offset: location.payloadOffset, count: 16)
        XCTAssertEqual(head, payload.prefix(16))
    }

    func testReadPastEOFThrowsTypedError() throws {
        let url = directory.appendingPathComponent("short.bin")
        try Data(count: 8).write(to: url)
        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }

        XCTAssertThrowsError(try file.read(offset: 4, count: 16)) { error in
            guard case .unexpectedEOF? = error as? Edge0TensorStoreError else {
                return XCTFail("Expected unexpectedEOF, got \(error)")
            }
        }
    }

    func testClosedStoreRejectsReadsAndDoubleCloseIsSafe() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let store = try Edge0PreadTensorStore(path: url.path, shardName: "model.safetensors")
        await store.close()
        await store.close()

        do {
            _ = try await store.read(location)
            XCTFail("Expected closed error")
        } catch {
            guard case .closed? = error as? Edge0TensorStoreError else {
                return XCTFail("Expected closed, got \(error)")
            }
        }
    }

    func testConcurrentReadsAreIndependent() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = Edge0TestFixtures.payload(shape: [128], dtype: .u32)
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [128], payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"],
            maxConcurrentReads: 2
        )
        defer { Task { await stores.closeAll() } }

        async let first = stores.read(location)
        async let second = stores.read(location)
        let results = try await [first, second]
        XCTAssertEqual(results[0].bytes, payload)
        XCTAssertEqual(results[1].bytes, payload)
    }

    func testCancelledContextThrowsBeforeRead() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let store = try Edge0PreadTensorStore(path: url.path, shardName: "model.safetensors")

        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await store.read(location)
                return nil
            } catch {
                return error
            }
        }
        let error = await task.value
        XCTAssertTrue(
            error is CancellationError,
            "Expected CancellationError, got \(String(describing: error))"
        )
    }

    func testStoreSetRejectsUnknownShard() async throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"]
        )
        defer { Task { await stores.closeAll() } }

        let ghost = Edge0TensorLocation(
            name: location.name,
            shard: "other.safetensors",
            payloadOffset: location.payloadOffset,
            byteCount: location.byteCount,
            dtype: location.dtype,
            shape: location.shape
        )
        do {
            _ = try await stores.read(ghost)
            XCTFail("Expected unknownShard")
        } catch {
            guard case .unknownShard? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected unknownShard, got \(error)")
            }
        }
    }

    // MARK: - Advisory readahead (Phase 5M)

    func testReadaheadRangeAlignmentOutwardAndClamp() {
        let pageSize: UInt64 = 4096

        // Request turning into two pages even though it starts and ends
        // inside page 1.
        let inner = Edge0Readahead.alignedRange(
            offset: 9, count: 5, fileSize: 100_000, pageSize: pageSize
        )
        XCTAssertEqual(inner?.offset, 0)
        XCTAssertEqual(inner?.count, pageSize)

        // A tail slice is clamped to the file end (no aligned overflow).
        let tail = Edge0Readahead.alignedRange(
            offset: 99_000, count: 5_000, fileSize: 100_000, pageSize: pageSize
        )
        XCTAssertEqual(tail?.offset, 98_304)
        XCTAssertEqual((tail?.offset ?? 0) + (tail?.count ?? 0), 100_000)

        // Larger request than the file: whole remainder is hinted once.
        let whole = Edge0Readahead.alignedRange(
            offset: 0, count: 1_000_000, fileSize: 100_000, pageSize: pageSize
        )
        XCTAssertEqual(whole?.offset, 0)
        XCTAssertEqual(whole?.count, 100_000)
    }

    func testReadaheadRangeRefusedCases() {
        let pageSize: UInt64 = 4096
        XCTAssertNil(Edge0Readahead.alignedRange(
            offset: 0, count: 0, fileSize: 100_000, pageSize: pageSize
        ))
        XCTAssertNil(Edge0Readahead.alignedRange(
            offset: 0, count: 5, fileSize: 0, pageSize: pageSize
        ))
        XCTAssertNil(Edge0Readahead.alignedRange(
            offset: 100_000, count: 5, fileSize: 100_000, pageSize: pageSize
        ))
        XCTAssertNil(Edge0Readahead.alignedRange(
            offset: 5, count: 5, fileSize: 100_000, pageSize: 1
        ))
    }

    func testReadaheadHintIssuedAndNeverThrows() throws {
        let url = directory.appendingPathComponent("advise.bin")
        try Data(count: 100_000).write(to: url)
        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }

        XCTAssertTrue(file.advise(offset: 9, count: 5))
        XCTAssertTrue(file.advise(offset: 0, count: 100_000))
        // Out-of-range or zero-length hints are no-ops without a syscall.
        XCTAssertFalse(file.advise(offset: 100_000, count: 5))
        XCTAssertFalse(file.advise(offset: 0, count: 0))
    }

    func testReadaheadHintOnStoreSetSkipsUnknownOrOversizedSlices() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [16], Data(count: 64)),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: ["model.safetensors"],
            maxConcurrentReads: 2
        )
        defer { Task { await stores.closeAll() } }

        XCTAssertTrue(stores.adviseSlice(location, byteOffset: 0, byteLength: 64))
        // Out-of-range slice: silently no-op.
        XCTAssertFalse(
            stores.adviseSlice(location, byteOffset: 96, byteLength: 64)
        )
        // Unknown shard: silently no-op.
        let ghost = Edge0TensorLocation(
            name: location.name,
            shard: "other.safetensors",
            payloadOffset: location.payloadOffset,
            byteCount: location.byteCount,
            dtype: location.dtype,
            shape: location.shape
        )
        XCTAssertFalse(stores.adviseSlice(ghost, byteOffset: 0, byteLength: 64))
    }

    // MARK: - Uninitialized-buffer read (zero-fill removal)
    //
    // `Edge0PreadFile.read` allocates its destination UNINITIALIZED and hands
    // ownership to `Data` only after the read fully succeeds. These tests pin
    // the two properties that change makes riskier than `Data(count:)`:
    // every byte must be filled by the pread (no stale/garbage tail), and the
    // returned buffer must be owned independently of the file descriptor so a
    // later close cannot invalidate it.

    /// A short read must still fill every byte: an uninitialized block would
    /// leave the untouched tail as garbage instead of zeros.
    func testReadFillsEveryByteOfUninitializedBuffer() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        // Distinct, non-zero pattern so a stale or zero-filled buffer cannot
        // accidentally compare equal.
        let payload = Data((0..<1024).map { UInt8(($0 * 7 + 13) % 251) })
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U8", [1024], payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }

        XCTAssertEqual(try file.read(offset: location.payloadOffset, count: 1024), payload)
        // Partial reads are exact slices, not zero-padded.
        XCTAssertEqual(
            try file.read(offset: location.payloadOffset + 100, count: 256),
            payload.dropFirst(100).prefix(256)
        )
    }

    /// The returned `Data` must own its storage: closing the descriptor
    /// afterwards cannot invalidate or mutate the bytes already read.
    func testReadDataOutlivesClosedFileDescriptor() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = Data((0..<512).map { UInt8($0 % 255) })
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U8", [512], payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let file = try Edge0PreadFile(path: url.path)
        let read = try file.read(offset: location.payloadOffset, count: 512)
        file.close()

        XCTAssertEqual(read, payload)
        // Force allocation churn that could reuse the freed block, then the
        // data must still be intact (proves no aliasing of a recycled buffer).
        for _ in 0..<50 {
            _ = try Data(contentsOf: url)
        }
        XCTAssertEqual(read, payload)
    }

    /// Mutating the returned `Data` must not affect later reads (unique
    /// storage per read, no shared backing buffer).
    func testMutatingReadResultDoesNotAffectSubsequentReads() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let payload = Data(repeating: 0xAB, count: 256)
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U8", [256], payload),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let location = try index.location("a.weight")

        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }

        var first = try file.read(offset: location.payloadOffset, count: 256)
        first[0] = 0x00
        first[255] = 0xFF

        XCTAssertEqual(
            try file.read(offset: location.payloadOffset, count: 256),
            payload
        )
    }

    /// The failure path must release the block it allocated rather than leak
    /// it.
    ///
    /// Making this detectable is the subtle part: `phys_footprint` only counts
    /// COMMITTED pages, so a read that fails immediately (small file, huge
    /// request) leaks an untouched allocation that stays resident-zero and is
    /// invisible to the assertion. This test therefore starts the read INSIDE
    /// a real 576 KiB file and runs it past EOF, so `pread` commits nearly the
    /// whole buffer before throwing. Leaked, those buffers are resident and the
    /// footprint grows by ~337 MiB over 600 iterations; released, it stays
    /// flat. Verified by re-running with the `deallocate()` deliberately
    /// removed (growth 339.0 MiB, assertion fails).
    func testRepeatedFailedReadsDoNotAccumulateAllocations() throws {
        let url = directory.appendingPathComponent("commit.bin")
        let sliceBytes = 589_824
        try Data((0..<sliceBytes).lazy.map { UInt8($0 % 251) }).write(to: url)
        let file = try Edge0PreadFile(path: url.path)
        defer { file.close() }

        func footprintBytes() -> Int64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(
                MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : -1
        }

        // Warm up so allocator arenas exist before measuring.
        var threwEOF = 0
        for _ in 0..<20 {
            do {
                _ = try file.read(offset: 1_024, count: sliceBytes)
                XCTFail("an over-EOF read must throw")
            } catch let error as Edge0TensorStoreError {
                if case .unexpectedEOF = error { threwEOF += 1 }
            }
        }

        let before = footprintBytes()
        for _ in 0..<600 {
            do {
                _ = try file.read(offset: 1_024, count: sliceBytes)
                XCTFail("an over-EOF read must throw")
            } catch let error as Edge0TensorStoreError {
                if case .unexpectedEOF = error { threwEOF += 1 }
            }
        }
        let growthMB = Double(footprintBytes() - before) / 1_048_576

        XCTAssertEqual(threwEOF, 620)
        XCTAssertLessThan(
            growthMB, 40,
            "the failure path must deallocate its buffer (grew \(growthMB) MiB)"
        )

        // The store must still serve valid reads afterwards. The file content
        // is byteIndex % 251, so the first 64 bytes are 0...63, not zeros.
        let expected = Data((0..<64).map { UInt8($0 % 251) })
        XCTAssertEqual(try file.read(offset: 0, count: 64), expected)
    }
}
