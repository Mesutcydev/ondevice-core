import XCTest
@testable import IOSLocalLLM

// MARK: - ModelStoragePathsTests
//
// Pins the canonical sandbox model paths so no subsystem can drift onto a
// relative, root-level, or security-scoped URL (the regression class that
// produced the "permission to save in LLMModels" failure).

final class ModelStoragePathsTests: XCTestCase {

    func testCanonicalRootsAreInsideSandboxDocuments() {
        let documents = ModelStoragePaths.documents
        XCTAssertEqual(documents.lastPathComponent, "Documents")

        let llmModels = ModelStoragePaths.llmModels
        XCTAssertEqual(llmModels.lastPathComponent, "LLMModels")
        XCTAssertEqual(llmModels.deletingLastPathComponent(), documents)
        XCTAssertTrue(ModelStoragePaths.isInsideSandbox(llmModels))
    }

    func testModelDirectoryIsInsideCanonicalRoot() {
        let modelDir = ModelStoragePaths.llmModelDirectory(
            named: "Edge0-8B-A1B-preview"
        )
        XCTAssertEqual(
            modelDir.deletingLastPathComponent(),
            ModelStoragePaths.llmModels
        )
        XCTAssertTrue(ModelStoragePaths.isInsideSandbox(modelDir))
    }

    func testRootLevelPathsAreRejected() {
        XCTAssertFalse(ModelStoragePaths.isInsideSandbox(URL(fileURLWithPath: "/")))
        XCTAssertFalse(ModelStoragePaths.isInsideSandbox(URL(fileURLWithPath: "/LLMModels")))
        XCTAssertFalse(ModelStoragePaths.isInsideSandbox(URL(fileURLWithPath: "/tmp/LLMModels")))
    }

    func testRepoNamingConventions() {
        XCTAssertEqual(
            ModelStoragePaths.directoryName(forRepoID: "Edge0/Edge0-8B-A1B-preview"),
            "Edge0-8B-A1B-preview"
        )
        XCTAssertEqual(
            ModelStoragePaths.flattenedRepoID("Edge0/Edge0-8B-A1B-preview"),
            "Edge0_Edge0-8B-A1B-preview"
        )
    }

    func testNestedDirectoryCreationUnderATempRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )

        let target = root
            .appendingPathComponent("LLMModels", isDirectory: true)
            .appendingPathComponent("Edge0-8B-A1B-preview", isDirectory: true)
        try ModelStoragePaths.createDirectory(at: target, root: root)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: target.path, isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertTrue(ModelStoragePaths.isInside(root: root, target))
    }

    func testCreationOutsideRootIsRejectedBeforeAnyWrite() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = URL(fileURLWithPath: "/LLMModels")

        XCTAssertThrowsError(
            try ModelStoragePaths.createDirectory(at: outside, root: root)
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("outside the app container"),
                "Got: \(error.localizedDescription)"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/LLMModels"))
    }

    func testKnownRootsAreAllInsideTheSandbox() {
        for root in ModelStoragePaths.modelRoots {
            XCTAssertTrue(
                ModelStoragePaths.isInsideSandbox(root),
                "\(root.path) escaped the sandbox"
            )
        }
    }

    func testSandboxRelativePathStripsContainerPrefix() {
        let inside = ModelStoragePaths.llmModelDirectory(named: "Edge0-8B-A1B-preview")
        XCTAssertEqual(
            ModelStoragePaths.sandboxRelativePath(inside),
            "Documents/LLMModels/Edge0-8B-A1B-preview"
        )
        XCTAssertEqual(
            ModelStoragePaths.sandboxRelativePath(URL(fileURLWithPath: "/LLMModels")),
            "outside-container"
        )
    }

    func testWritabilityProbeSucceedsAndLeavesNoFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try ModelStoragePaths.probeWritability(of: root)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(leftovers.isEmpty, "probe must not leave files behind")
    }

    func testWritabilityProbeReportsMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertThrowsError(try ModelStoragePaths.probeWritability(of: missing)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Write probe failed"))
        }
    }

    func testReconciledDestinationRejectsStaleContainerPaths() {
        let stale = InstalledModelRecord(
            id: UUID(),
            repoID: "Edge0/Edge0-8B-A1B-preview",
            displayName: "Edge0-8B A1B",
            localURL: URL(fileURLWithPath: "/var/mobile/Containers/Data/Application/OLD-UUID/Documents/LLMModels/Edge0-8B-A1B-preview"),
            engine: .edge0MLX,
            capabilities: [],
            architecture: "BailingMoeV3ForCausalLM",
            quantization: "4bit",
            parameterCount: nil,
            installedAt: Date(),
            validationState: .valid,
            downloadBytes: 0
        )
        XCTAssertEqual(
            ModelDownloadCenter.reconciledDestination(for: stale),
            ModelStoragePaths.llmModelDirectory(named: "Edge0-8B-A1B-preview"),
            "A path outside the current sandbox must never be a download destination"
        )

        let inSandbox = InstalledModelRecord(
            id: UUID(),
            repoID: "Edge0/Edge0-8B-A1B-preview",
            displayName: "Edge0-8B A1B",
            localURL: ModelStoragePaths.llmModelDirectory(named: "Edge0-8B-A1B-preview"),
            engine: .edge0MLX,
            capabilities: [],
            architecture: "BailingMoeV3ForCausalLM",
            quantization: "4bit",
            parameterCount: nil,
            installedAt: Date(),
            validationState: .valid,
            downloadBytes: 0
        )
        XCTAssertEqual(
            ModelDownloadCenter.reconciledDestination(for: inSandbox),
            inSandbox.localURL
        )
    }

    func testFailureDescriptionKeepsPathAndUnderlyingError() {
        let underlying = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
        let message = ModelStoragePathError.describeFailure(
            path: "/sandbox/Documents/LLMModels",
            error: underlying
        )
        XCTAssertTrue(message.contains("/sandbox/Documents/LLMModels"))
        XCTAssertTrue(message.contains(NSPOSIXErrorDomain))
        XCTAssertTrue(message.contains("\(EACCES)"))
    }
}
