import XCTest
@testable import IOSLocalLLM

// MARK: - Edge0SafetensorsTests

final class Edge0SafetensorsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try Edge0TestFixtures.makeTemporaryDirectory("safetensors")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testValidTinyFileIndexesWithoutReadingPayload() throws {
        let url = directory.appendingPathComponent("model.safetensors")
        let weightPayload = Edge0TestFixtures.payload(
            shape: [2, 3],
            dtype: .u32
        )
        let scalePayload = Edge0TestFixtures.payload(
            shape: [3],
            dtype: .bf16
        )
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("a.weight", "U32", [2, 3], weightPayload),
            ("b.scales", "BF16", [3], scalePayload),
        ])

        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        XCTAssertEqual(index.tensorCount, 2)
        XCTAssertEqual(index.shardNames, ["model.safetensors"])

        let location = try index.location("a.weight")
        XCTAssertEqual(location.dtype, .u32)
        XCTAssertEqual(location.shape, [2, 3])
        XCTAssertEqual(location.byteCount, 24)
        XCTAssertEqual(location.shard, "model.safetensors")

        let readBack = try Edge0FileIO.readExactly(
            at: url,
            offset: location.payloadOffset,
            count: Int(location.byteCount)
        )
        XCTAssertEqual(readBack, weightPayload, "payload offset must point at the tensor bytes")

        let row = try location.row(1)
        XCTAssertEqual(row.byteCount, 12)
        XCTAssertEqual(row.shape, [3])
        XCTAssertEqual(row.payloadOffset, location.payloadOffset + 12)
    }

    func testMalformedHeaderIsRejected() throws {
        let url = directory.appendingPathComponent("bad.safetensors")
        try Edge0TestFixtures.writeRaw(
            at: url,
            header: Data("{not json".utf8),
            payload: Data()
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .malformedHeader? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected malformedHeader, got \(error)")
            }
        }
    }

    func testHeaderLengthPastEOFIsRejected() throws {
        let url = directory.appendingPathComponent("short.safetensors")
        var data = Data()
        var length = UInt64(1_000_000).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(Data("{}".utf8))
        try data.write(to: url)

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .headerLengthOutOfRange? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected headerLengthOutOfRange, got \(error)")
            }
        }
    }

    func testOversizedHeaderIsRejectedBeforeReading() throws {
        let url = directory.appendingPathComponent("huge.safetensors")
        let declared = Edge0SafetensorsHeaderParser.maximumHeaderBytes + 1
        var data = Data()
        var length = declared.littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        try data.write(to: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 8 + declared)
        try handle.close()

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .headerTooLarge(let value, let maximum)? =
                error as? Edge0SafetensorsError else {
                return XCTFail("Expected headerTooLarge, got \(error)")
            }
            XCTAssertEqual(value, declared)
            XCTAssertEqual(maximum, Edge0SafetensorsHeaderParser.maximumHeaderBytes)
        }
    }

    func testRangePastEOFIsRejected() throws {
        let url = directory.appendingPathComponent("range.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"U32","shape":[4],"data_offsets":[0,16]}}"#,
            payload: Data(count: 8)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .tensorRangeOutOfBounds? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected tensorRangeOutOfBounds, got \(error)")
            }
        }
    }

    func testOffsetOverflowIsRejected() throws {
        let url = directory.appendingPathComponent("overflow.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"U32","shape":[2],"data_offsets":[0,18446744073709551615]}}"#,
            payload: Data(count: 8)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .integerOverflow? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected integerOverflow, got \(error)")
            }
        }
    }

    func testReversedDataOffsetsAreRejected() throws {
        let url = directory.appendingPathComponent("reversed.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"U32","shape":[2],"data_offsets":[8,0]}}"#,
            payload: Data(count: 8)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .invalidDataOffsets? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected invalidDataOffsets, got \(error)")
            }
        }
    }

    func testUnsupportedDTypeIsRejected() throws {
        let url = directory.appendingPathComponent("dtype.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"F8_E4M3","shape":[1],"data_offsets":[0,1]}}"#,
            payload: Data(count: 1)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .unsupportedDType(let dtype)? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected unsupportedDType, got \(error)")
            }
            XCTAssertEqual(dtype, "F8_E4M3")
        }
    }

    func testShapeByteMismatchIsRejected() throws {
        let url = directory.appendingPathComponent("shape.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"U32","shape":[3],"data_offsets":[0,8]}}"#,
            payload: Data(count: 8)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .invalidShape? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected invalidShape, got \(error)")
            }
        }
    }

    func testDuplicateTensorNameIsRejected() throws {
        let url = directory.appendingPathComponent("duplicate.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"t":{"dtype":"U32","shape":[2],"data_offsets":[0,8]},"t":{"dtype":"U32","shape":[2],"data_offsets":[8,16]}}"#,
            payload: Data(count: 16)
        )

        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSingleFile(at: url)) { error in
            guard case .duplicateTensor(let name)? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected duplicateTensor, got \(error)")
            }
            XCTAssertEqual(name, "t")
        }
    }

    func testMetadataBlockIsIgnored() throws {
        let url = directory.appendingPathComponent("metadata.safetensors")
        try Edge0TestFixtures.writeRawSafetensors(
            at: url,
            headerJSON: #"{"__metadata__":{"format":"pt"},"t":{"dtype":"U32","shape":[1],"data_offsets":[0,4]}}"#,
            payload: Data(count: 4)
        )
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        XCTAssertEqual(index.tensorCount, 1)
        XCTAssertTrue(index.contains("t"))
        XCTAssertFalse(index.contains("__metadata__"))
    }

    func testMissingTensorLookupThrows() throws {
        let url = directory.appendingPathComponent("missing.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: url, tensors: [
            ("present.weight", "U32", [1], Data(count: 4)),
        ])
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        XCTAssertThrowsError(try index.location("absent.weight")) { error in
            guard case .missingTensor(let name)? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected missingTensor, got \(error)")
            }
            XCTAssertEqual(name, "absent.weight")
        }
    }

    func testShardedIndexMapsTensorsAcrossShards() throws {
        let shardA = directory.appendingPathComponent("model-00001-of-00002.safetensors")
        let shardB = directory.appendingPathComponent("model-00002-of-00002.safetensors")
        try Edge0TestFixtures.writeSafetensors(at: shardA, tensors: [
            ("a.weight", "U32", [1], Data(count: 4)),
        ])
        try Edge0TestFixtures.writeSafetensors(at: shardB, tensors: [
            ("b.weight", "U32", [1], Data(count: 4)),
        ])
        let indexJSON = """
        {"metadata":{},"weight_map":{"a.weight":"model-00001-of-00002.safetensors","b.weight":"model-00002-of-00002.safetensors"}}
        """
        try Data(indexJSON.utf8).write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )

        let index = try Edge0SafetensorsIndex.openSharded(in: directory)
        XCTAssertEqual(index.tensorCount, 2)
        XCTAssertEqual(try index.location("a.weight").shard, "model-00001-of-00002.safetensors")
        XCTAssertEqual(try index.location("b.weight").shard, "model-00002-of-00002.safetensors")
    }

    func testShardedIndexWithMissingShardThrows() throws {
        let indexJSON = """
        {"weight_map":{"a.weight":"model-00001-of-00002.safetensors"}}
        """
        try Data(indexJSON.utf8).write(
            to: directory.appendingPathComponent("model.safetensors.index.json")
        )
        XCTAssertThrowsError(try Edge0SafetensorsIndex.openSharded(in: directory)) { error in
            guard case .unknownShard? = error as? Edge0SafetensorsError else {
                return XCTFail("Expected unknownShard, got \(error)")
            }
        }
    }
}
