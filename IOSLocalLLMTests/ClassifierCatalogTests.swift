import Foundation
import XCTest
@testable import IOSLocalLLM

final class ClassifierCatalogTests: XCTestCase {
    func testCompilationReservesSpaceForTemporaryAndInstalledOutputs() throws {
        let package = try XCTUnwrap(ClassifierCatalog.model(id: "laya-english-128"))
        XCTAssertGreaterThan(package.compilationHeadroom, package.bytes)
        XCTAssertEqual(try XCTUnwrap(ClassifierCatalog.model(id: "laya-multilingual-128-e8")).compilationHeadroom, 0)
        XCTAssertEqual(try XCTUnwrap(ClassifierCatalog.model(id: "julia-1-q8")).compilationHeadroom, 0)
    }
    func testCatalogIsPinnedUniqueAndSeparateFromAssistant() throws {
        let models = ClassifierCatalog.models
        XCTAssertEqual(models.count, 13)
        XCTAssertEqual(Set(models.map(\.selectionID)).count, models.count)
        XCTAssertEqual(models.filter(\.isImage).count, 2)
        XCTAssertEqual(models.filter { $0.runtime == .gguf }.count, 4)
        for model in models {
            XCTAssertTrue(model.selectionID.hasPrefix("classifier:"))
            XCTAssertEqual(model.revision.count, 40)
            XCTAssertTrue(model.revision.allSatisfy(\.isHexDigit))
            XCTAssertGreaterThan(model.estimatedPeak, model.bytes)
            XCTAssertEqual(ClassifierCatalog.model(id: model.selectionID)?.id, model.id)
            XCTAssertTrue(model.includes(remotePath: model.asset))
            XCTAssertFalse(model.includes(remotePath: "other-model.gguf"))
            XCTAssertFalse(model.includes(remotePath: model.asset + "-other/weights.bin"))
            XCTAssertTrue(model.sidecars.allSatisfy { model.includes(remotePath: $0) })
        }
    }
    func testCatalogAssetContainmentRejectsTraversalAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["../outside", "/absolute", "a//b", "a/./b", "https://host/file", "a\\b"] {
            XCTAssertThrowsError(try ClassifierCatalogModel.containedURL(path, in: root))
        }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try ClassifierCatalogModel.containedURL("escape/file", in: root))
        XCTAssertEqual(try ClassifierCatalogModel.containedURL("asset/weights.bin", in: root).lastPathComponent, "weights.bin")
    }
    func testPortableContractRefusesInvalidCalibrationAndSpecialTokens() throws {
        XCTAssertThrowsError(try CoreAIClassifierContract(layout: .laya, window: 8, headBudget: 8, vocabSize: 100,
            cls: 2, sep: 1, pad: 0, mask: 4, sourceTemperatures: [1, 1, 1]))
        XCTAssertThrowsError(try CoreAIClassifierContract(layout: .laya, window: 128, headBudget: 64, vocabSize: 100,
            cls: 2, sep: 1, pad: 0, mask: 4, sourceTemperatures: [1, .nan, 1]))
        XCTAssertThrowsError(try CoreAIClassifierContract(layout: .laya, window: 128, headBudget: 64, vocabSize: 100,
            cls: 2, sep: 1, pad: 0, mask: 2, sourceTemperatures: [1, 1, 1]))
        let contract = try CoreAIClassifierContract(layout: .laya, window: 128, headBudget: 64, vocabSize: 100,
            cls: 2, sep: 1, pad: 0, mask: 4, sourceTemperatures: [1, 1, 1])
        let row = try CoreAIClassifierAdapter.buildInput(contract: contract, state: "draft", question: .boolean(instructions: "Check"), encode: { _ in [5] })
        XCTAssertEqual(row.markers.count, 2)
        XCTAssertEqual(row.inputIDs.count, 128)
    }
}
