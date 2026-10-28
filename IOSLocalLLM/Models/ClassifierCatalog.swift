import Foundation

/// Pinned, opt-in classifier downloads. Tensor contracts are implemented by
/// PortableClassifierRuntime; these are never Assistant generation models.
struct ClassifierCatalogModel: Identifiable, Sendable {
    enum Runtime: String, Sendable { case gguf, coreML }
    let id: String
    let name: String
    let repo: String
    let revision: String
    let asset: String
    let sidecars: [String]
    let bytes: Int64
    let window: Int
    let runtime: Runtime
    var layout: CoreAIClassifierContract.Layout = .laya
    var isImage = false
    var license = "Apache-2.0"
    var selectionID: String { "classifier:\(id)" }
    var estimatedPeak: Int64 { bytes * 2 + 300_000_000 }
    /// The compiler output and its staged copy coexist briefly with the source.
    var compilationHeadroom: Int64 { asset.hasSuffix(".mlpackage") ? bytes * 2 : 0 }
    var summary: String {
        isImage ? "ImageNet image categories · local Core ML" : "Choice, score and yes/no · \(window) tokens · \(runtime == .gguf ? "CPU" : "Core ML")"
    }

    func includes(remotePath: String) -> Bool {
        remotePath == asset || remotePath.hasPrefix(asset + "/") || sidecars.contains(remotePath)
    }

    func assetURL(in root: URL) throws -> URL {
        try Self.containedURL(asset, in: root)
    }

    static func containedURL(_ path: String, in root: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.contains(":"), !path.contains("\\"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw CoreAIClassifierError.unsafeAssetPath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var componentURL = base
        for part in parts {
            componentURL.appendPathComponent(String(part))
            if let attributes = try? FileManager.default.attributesOfItem(atPath: componentURL.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw CoreAIClassifierError.unsafeAssetPath }
        }
        let url = base.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw CoreAIClassifierError.unsafeAssetPath }
        return url
    }
}

enum ClassifierCatalog {
    static let models: [ClassifierCatalogModel] = [
        gguf("julia-1-q8", "Julia-1 · 8-bit", "ggml-org/Julia-1-GGUF", "16fee17949206fbf58da9347daea44d792a81211", "Julia-1-Q8_0.gguf", 168_166_496, .julia),
        gguf("julia-1-bf16", "Julia-1 · BF16", "ggml-org/Julia-1-GGUF", "16fee17949206fbf58da9347daea44d792a81211", "Julia-1-BF16.gguf", 303_319_136, .julia),
        gguf("laya-gguf-q8", "Laya English · 8-bit", "ggml-org/laya-GGUF", "22265007700297ba9e128297e82540cf28c5d7d4", "Laya-Q8_0.gguf", 449_397_600, .laya),
        gguf("laya-gguf-bf16", "Laya English · BF16", "ggml-org/laya-GGUF", "22265007700297ba9e128297e82540cf28c5d7d4", "Laya-BF16.gguf", 844_026_720, .laya),
        multilingual(128, true, 482_857_269), multilingual(256, true, 483_086_647),
        multilingual(512, true, 483_938_616), multilingual(1_024, true, 487_216_685),
        multilingual(512, false, 679_777_431), english(128, 846_772_027), english(512, 847_951_675),
        .init(id: "fastvit-t8", name: "FastViT T8", repo: "apple/coreml-FastViT-T8", revision: "b42811edaa9f7ca6d79eeada204227704484c881", asset: "FastViTT8F16.mlpackage", sidecars: ["LICENSE"], bytes: 8_129_286, window: 0, runtime: .coreML, isImage: true, license: "Apple Sample Code License"),
        .init(id: "fastvit-ma36", name: "FastViT MA36", repo: "apple/coreml-FastViT-MA36", revision: "29f9a1fa017169eb29bdfe3747cfcfcd88a0e03e", asset: "FastViTMA36F16.mlpackage", sidecars: ["LICENSE"], bytes: 88_289_183, window: 0, runtime: .coreML, isImage: true, license: "Apple Sample Code License")
    ]

    static func model(id: String) -> ClassifierCatalogModel? { models.first { $0.id == id || $0.selectionID == id } }

    private static func gguf(_ id: String, _ name: String, _ repo: String, _ revision: String, _ asset: String, _ bytes: Int64, _ layout: CoreAIClassifierContract.Layout) -> ClassifierCatalogModel {
        .init(id: id, name: name, repo: repo, revision: revision, asset: asset, sidecars: ["README.md"], bytes: bytes, window: layout == .julia ? 1_024 : 512, runtime: .gguf, layout: layout)
    }
    private static func multilingual(_ length: Int, _ compact: Bool, _ bytes: Int64) -> ClassifierCatalogModel {
        let precision = compact ? "e8" : "fp16"
        return .init(id: "laya-multilingual-\(length)-\(precision)", name: "Laya Multilingual · \(length) · \(precision.uppercased())", repo: "FluidInference/laya-coreml", revision: "7b8d7a2b7e28e746c6ecaad44bbcd5cf251a4fcc", asset: "laya_multilingual_\(precision)_L\(length)_options32.mlmodelc", sidecars: ["config.json", "tokenizer.json", "LICENSE", "NOTICE.md"], bytes: bytes, window: length, runtime: .coreML)
    }
    private static func english(_ length: Int, _ bytes: Int64) -> ClassifierCatalogModel {
        .init(id: "laya-english-\(length)", name: "Laya English · \(length) · FP16", repo: "FluidInference/laya-english-coreml", revision: "78c0b0e5054eb5804c72080016227d4f3b0bd08d", asset: "laya_english_fp16_L\(length)_options32.mlpackage", sidecars: ["config.json", "rl_agent_config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "LICENSE"], bytes: bytes, window: length, runtime: .coreML)
    }
}
