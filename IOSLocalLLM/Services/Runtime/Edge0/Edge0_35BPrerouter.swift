import Foundation
import MLX

// MARK: - Edge0_35BPrerouterError

enum Edge0_35BPrerouterError: Error, Equatable, Sendable {
    case incompatibleHead(Int)
    case noHead(Int)
}

// MARK: - Edge0_35BPrerouter
//
// Phase 5J advisory predictor: faithful port of the pinned upstream
// cross-token head. Owner layer N predicts the experts layer N+1 will need.
//
//   features = concat[m_in (hidden), current executed top-k one-hot (E),
//                     previous-token executed top-k one-hot (E)]  -> F16
//   logits   = linear_init(features) + fc2(gelu_erf(fc1(features)))
//   selection = precise softmax -> trailing-k argpartition -> renormalize
//               (identical formulation to the true router)
//
// Predictions are advisory only: they may request low-priority loads; the
// true router always decides the executed experts and their weights.

struct Edge0_35BPrerouterHead: @unchecked Sendable {
    let owner: Int
    let fc1Weight: MLXArray      // [512, hidden + 2E] F16
    let fc2Weight: MLXArray      // [E, 512] F16
    let linearInitWeight: MLXArray  // [E, hidden + 2E] F16
}

final class Edge0_35BPrerouter: @unchecked Sendable {
    static let artifactName = "prerouter_edge0_35b.safetensors"
    /// Released owner range: 6...38 (absent owners are never failures).
    static let ownerRange: ClosedRange<Int> = 6...38
    static let numExperts = 256
    static let hidden = 2048
    static let topK = 4

    let heads: [Int: Edge0_35BPrerouterHead]

    private init(heads: [Int: Edge0_35BPrerouterHead]) {
        self.heads = heads
    }

    static func artifactURL(in directory: URL) -> URL {
        directory.appendingPathComponent(artifactName)
    }

    static func isAvailable(in directory: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: artifactURL(in: directory).path
        )
    }

    /// Loads the optional artifact. nil when absent (never an error); throws
    /// only when present but unusable, so a malformed predictor disables
    /// advisory prediction instead of running with bad weights.
    static func load(directory: URL) async throws -> Edge0_35BPrerouter? {
        guard isAvailable(in: directory) else { return nil }
        let url = artifactURL(in: directory)
        let index = try Edge0SafetensorsIndex.openSingleFile(at: url)
        let stores = try Edge0TensorStoreSet(
            directory: directory, shardNames: [artifactName]
        )
        let loader = Edge0ResidentTensorLoader(index: index, stores: stores)
        var heads: [Int: Edge0_35BPrerouterHead] = [:]
        for owner in ownerRange {
            guard index.contains("layers.\(owner).fc1.weight") else {
                continue
            }
            let fc1 = try await loader.load(
                index.location("layers.\(owner).fc1.weight")
            )
            let fc2 = try await loader.load(
                index.location("layers.\(owner).fc2.weight")
            )
            let linearInit = try await loader.load(
                index.location("layers.\(owner).linear_init.weight")
            )
            guard fc1.dim(0) == 512,
                  fc1.dim(1) == hidden + 2 * numExperts,
                  fc2.dim(0) == numExperts, fc2.dim(1) == 512,
                  linearInit.dim(0) == numExperts,
                  linearInit.dim(1) == hidden + 2 * numExperts else {
                throw Edge0_35BPrerouterError.incompatibleHead(owner)
            }
            heads[owner] = Edge0_35BPrerouterHead(
                owner: owner,
                fc1Weight: fc1.asType(.float16),
                fc2Weight: fc2.asType(.float16),
                linearInitWeight: linearInit.asType(.float16)
            )
        }
        guard !heads.isEmpty else {
            throw Edge0_35BPrerouterError.incompatibleHead(-1)
        }
        await stores.closeAll()
        return Edge0_35BPrerouter(heads: heads)
    }

    func owns(_ owner: Int) -> Bool { heads[owner] != nil }

    var headCount: Int { heads.count }

    /// F16 tensor payload of the loaded heads (artifact file is slightly
    /// larger: header + alignment).
    var loadedPayloadBytes: UInt64 {
        UInt64(heads.count) * (2_621_440 + 262_144 + 1_310_720)
    }

    /// Set one-hot over the executed top-k ids: sum over K of eye[id].
    /// [B, T, K] ids -> [B, T, E] fp32 (then cast by the feature concat).
    static func topKOneHot(_ ids: MLXArray) -> MLXArray {
        let eye = MLX.eye(numExperts, dtype: .float32)
        return MLX.take(eye, ids.asType(.int32), axis: 0).sum(axis: -2)
    }

    /// Concatenated head features (cast F16 exactly as upstream).
    static func features(
        moeInput: MLXArray,
        executedIDs: MLXArray,
        previousOneHot: MLXArray?
    ) -> MLXArray {
        let current = topKOneHot(executedIDs)
        let previous: MLXArray
        if let previousOneHot {
            previous = previousOneHot.asType(.float32)
        } else {
            previous = MLXArray.zeros(
                [moeInput.dim(0), moeInput.dim(1), numExperts],
                dtype: .float32
            )
        }
        return MLX.concatenated(
            [moeInput.asType(.float32), current, previous], axis: -1
        ).asType(.float16)
    }

    /// Exact GELU (erf), matching upstream `gelu_erf`.
    static func geluErf(_ x: MLXArray) -> MLXArray {
        let scale = MLXArray(Float(1.0 / (2.0).squareRoot()))
        return 0.5 * x * (1.0 + MLX.erf(x * scale))
    }

    struct Forward: @unchecked Sendable {
        var hidden: MLXArray
        var fc2: MLXArray
        var linear: MLXArray
        var logits: MLXArray
    }

    /// Raw head math on prebuilt features (diagnostic/parity path).
    func forward(owner: Int, features: MLXArray) throws -> Forward {
        guard let head = heads[owner] else {
            throw Edge0_35BPrerouterError.noHead(owner)
        }
        let feats = features.asType(.float16)
        let h1 = MLX.matmul(feats, head.fc1Weight.T)
        let hidden = Self.geluErf(h1).asType(.float16)
        let fc2 = MLX.matmul(hidden, head.fc2Weight.T)
        let linear = MLX.matmul(feats, head.linearInitWeight.T)
        let logits = linear + fc2
        return Forward(
            hidden: hidden, fc2: fc2, linear: linear, logits: logits
        )
    }

    /// Selection with the true-router formulation (ties behave identically).
    static func select(logits: MLXArray, topK: Int = topK) -> ([Int], MLXArray) {
        let gates = MLX.softmax(logits, axis: -1, precise: true)
        let vocabulary = gates.dim(-1)
        let start = max(0, vocabulary - topK)
        let indices = MLX.argPartition(
            gates, kth: start, axis: -1
        )[.ellipsis, start...]
        var scores = MLX.takeAlong(gates, indices, axis: -1)
        scores = scores / (scores.sum(axis: -1, keepDims: true) + 1e-20)
        return (
            indices.asType(.int32).asArray(Int32.self).map { Int($0) },
            scores
        )
    }

    /// One advisory prediction for `owner` (predicts layer owner+1).
    func predict(
        owner: Int,
        moeInput: MLXArray,
        executedIDs: MLXArray,
        previousOneHot: MLXArray?
    ) throws -> (ids: [Int], logits: MLXArray) {
        let feats = Self.features(
            moeInput: moeInput,
            executedIDs: executedIDs,
            previousOneHot: previousOneHot
        )
        let forward = try forward(owner: owner, features: feats)
        let (ids, _) = Self.select(logits: forward.logits)
        return (ids, forward.logits)
    }
}

// MARK: - Edge0ExpertPredictor

extension Edge0_35BPrerouter: Edge0ExpertPredictor {
    /// Protocol requirement (labeled): claim only owners with a loaded head.
    func owns(owner: Int) -> Bool { heads[owner] != nil }

    func predictedExpertIDs(
        owner: Int,
        hidden: MLXArray,
        thisIDs: [Int],
        prevIDs: [Int],
        topK: Int
    ) throws -> [Int]? {
        guard owns(owner) else { return nil }
        let current = MLXArray(
            thisIDs.map { Int32($0) }, [1, 1, max(thisIDs.count, 1)]
        )
        let previous: MLXArray? = prevIDs.isEmpty ? nil : MLXArray(
            prevIDs.map { Int32($0) }, [1, 1, max(prevIDs.count, 1)]
        )
        let result = try predict(
            owner: owner,
            moeInput: hidden,
            executedIDs: current,
            previousOneHot: previous.map { Self.topKOneHot($0) }
        )
        return result.ids
    }
}
