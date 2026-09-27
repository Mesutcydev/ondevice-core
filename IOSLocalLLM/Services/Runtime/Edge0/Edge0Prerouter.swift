import Foundation
import MLX

// MARK: - Edge0PrerouterHead
//
// Exact port of upstream `edge0.prerouter.heads.PrerouterHead` (fp16):
//
//   feats = concat[hidden, this-token executed top-k one-hot,
//                  prev-token executed top-k one-hot]
//   logits = linear_init(feats) + fc2(exact_erf_gelu(fc1(feats)))
//
// Owned by layer N, it predicts layer N+1's routing from layer N's MoE
// input. Predictions are ADVISORY ONLY — the true router remains the sole
// authority on which experts execute.

struct Edge0PrerouterHead: @unchecked Sendable {
    let fc1Weight: MLXArray        // [prerouterHidden, hidden + 2*E]
    let fc2Weight: MLXArray        // [E, prerouterHidden]
    let linearInitWeight: MLXArray // [E, hidden + 2*E]

    func logits(
        hidden: MLXArray,
        thisOneHot: MLXArray,
        prevOneHot: MLXArray
    ) -> MLXArray {
        var feats = MLX.concatenated([hidden, thisOneHot, prevOneHot], axis: -1)
        if feats.dtype != .float16 {
            feats = feats.asType(.float16)
        }
        let hiddenOut = MLX.matmul(feats, fc1Weight.transposed(1, 0))
        let activated = Self.geluErf(hiddenOut)
        let predicted = MLX.matmul(activated, fc2Weight.transposed(1, 0))
        let skip = MLX.matmul(feats, linearInitWeight.transposed(1, 0))
        return skip + predicted
    }

    /// Exact (erf) GELU, matching torch `F.gelu` default and upstream
    /// `heads.gelu_erf`.
    static func geluErf(_ x: MLXArray) -> MLXArray {
        let scale = Float(2.0).squareRoot()
        return 0.5 * x * (1.0 + MLX.erf(x / scale))
    }
}

// MARK: - Edge0Prerouter
//
// Loaded advisory predictor. Artifact: `prerouter_edge0_8b.safetensors`
// (owners 7...22, fp16). Missing or incompatible artifact never invalidates
// the base model — callers fall back to `.staged`.

struct Edge0Prerouter: @unchecked Sendable {
    static let artifactName = "prerouter_edge0_8b.safetensors"

    let heads: [Int: Edge0PrerouterHead]
    let configuration: Edge0ModelConfiguration

    var ownerLayers: [Int] { heads.keys.sorted() }

    static func artifactURL(in directory: URL) -> URL {
        directory.appendingPathComponent(artifactName)
    }

    static func isAvailable(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: artifactURL(in: directory).path
        )
    }

    /// Loads and validates every owner head. Returns nil when the optional
    /// artifact is absent; throws only when it exists but is unusable.
    static func load(
        directory: URL,
        configuration: Edge0ModelConfiguration
    ) async throws -> Edge0Prerouter? {
        let url = artifactURL(in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory,
            shardNames: [artifactName]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)
        do {
            var heads: [Int: Edge0PrerouterHead] = [:]
            let expectedFeatureWidth =
                configuration.hiddenSize + 2 * configuration.numExperts
            let owners = configuration.numHiddenLayers - 1
            var loadedOwners = 0
            for owner in 7..<owners {
                guard (try? index.location("layers.\(owner).fc1.weight")) != nil
                else { continue }
                let fc1 = try await loader.load(
                    index.location("layers.\(owner).fc1.weight")
                )
                let fc2 = try await loader.load(
                    index.location("layers.\(owner).fc2.weight")
                )
                let linearInit = try await loader.load(
                    index.location("layers.\(owner).linear_init.weight")
                )
                // Shape contract: [512, hidden+2E] / [E, 512] / [E, hidden+2E].
                guard fc1.dim(0) == 512,
                      fc1.dim(1) == expectedFeatureWidth,
                      fc2.dim(0) == configuration.numExperts,
                      fc2.dim(1) == 512,
                      linearInit.dim(0) == configuration.numExperts,
                      linearInit.dim(1) == expectedFeatureWidth else {
                    throw Edge0PrerouterError.incompatibleHead(owner)
                }
                heads[owner] = Edge0PrerouterHead(
                    fc1Weight: fc1.asType(.float16),
                    fc2Weight: fc2.asType(.float16),
                    linearInitWeight: linearInit.asType(.float16)
                )
                loadedOwners += 1
            }
            guard loadedOwners > 0 else {
                throw Edge0PrerouterError.incompatibleHead(-1)
            }
            await stores.closeAll()
            return Edge0Prerouter(
                heads: heads,
                configuration: configuration
            )
        } catch {
            await stores.closeAll()
            throw error
        }
    }

    /// One-hot feature `[1, 1, E]` for a top-k selection.
    static func oneHot(ids: [Int], numExperts: Int) -> MLXArray {
        let index = MLXArray(ids.map { Int32($0) })
        let range = MLX.arange(numExperts).asType(.int32)
        return MLX.equal(
            index[0..., .newAxis],
            range[.newAxis, 0...]
        )
        .asType(.float16)
        .sum(axis: 0)
        .reshaped([1, 1, numExperts])
    }

    /// Advisory prediction for the consumer layer `owner + 1`.
    /// Uses the same SIGMOID_GROUP selection as the true router, without the
    /// gate's expert bias (upstream `LingPrerouterStager._select`).
    func predict(
        owner: Int,
        hidden: MLXArray,
        thisOneHot: MLXArray,
        prevOneHot: MLXArray,
        topK: Int
    ) -> Edge0RouterResult? {
        guard let head = heads[owner] else { return nil }
        let raw = head.logits(
            hidden: hidden,
            thisOneHot: thisOneHot,
            prevOneHot: prevOneHot
        )
        return Edge0Router.groupSelect(
            logits: raw.asType(.float32),
            expertBias: nil,
            numExperts: configuration.numExperts,
            numExpertsPerTok: topK,
            nGroup: configuration.nGroup,
            topkGroup: configuration.topkGroup,
            routedScalingFactor: Float(configuration.routedScalingFactor),
            normTopkProb: configuration.normTopkProb
        )
    }
}

// MARK: - Edge0PrerouterError

enum Edge0PrerouterError: Error, LocalizedError {
    case incompatibleHead(Int)

    var errorDescription: String? {
        switch self {
        case .incompatibleHead(let owner):
            return owner >= 0
                ? "Prerouter head for owner layer \(owner) has an incompatible shape."
                : "Prerouter artifact contains no compatible heads."
        }
    }
}
