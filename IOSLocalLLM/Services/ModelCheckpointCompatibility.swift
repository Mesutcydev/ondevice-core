import Foundation

/// Factorized LittleBit checkpoints have their own tensor layout. Recognize
/// explicit metadata rather than inferring compatibility from a repository
/// name or treating every binary checkpoint as an affine Bonsai model.
enum ModelCheckpointCompatibility {
    struct UnsupportedLittleBit: LocalizedError {
        var errorDescription: String? {
            "LittleBit and LittleBit-2 checkpoints need a factorized runtime that this app does not support yet. Choose an MLX affine checkpoint or a supported GGUF model."
        }
    }

    static func validateMLXDirectory(_ directory: URL) throws {
        if FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("littlebit_config.json").path
        ) {
            throw UnsupportedLittleBit()
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if identifiesLittleBit(config) { throw UnsupportedLittleBit() }
    }

    static func identifiesLittleBit(_ config: [String: Any]) -> Bool {
        let quantization = config["quantization_config"] as? [String: Any] ?? [:]
        let values = [config["quant_mod"], quantization["quant_method"], quantization["quant_mod"]]
        return values.compactMap { $0 as? String }.contains {
            $0.lowercased().replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: "_", with: "").hasPrefix("littlebit")
        }
    }
}
