import Foundation

/// Liquid's published GGUF artifacts. These are optional user downloads;
/// neither the weights nor the vision projector are bundled with the app.
enum LFM3Catalog {
    /// The production app keeps its validated shared runtime. An experimental
    /// build must explicitly select the separately bootstrapped LFM3 runtime.
    static var isEnabled: Bool {
        #if LFM3_EXPERIMENTAL
        true
        #else
        false
        #endif
    }

    struct Model: Equatable, Sendable {
        let repoID: String
        let revision: String
        let modelFilename: String
        let modelBytes: Int64
        let projectorFilename: String?
        let projectorBytes: Int64

        var downloadBytes: Int64 { modelBytes + projectorBytes }
        var fileAllowlist: [String] {
            [modelFilename] + (projectorFilename.map { [$0] } ?? []) + ["README.md", "LICENSE"]
        }
    }

    static let text = Model(
        repoID: "LiquidAI/LFM3-1.7B-GGUF",
        revision: "b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf",
        modelFilename: "LFM3-1.7B-QAD-Q4_0.gguf",
        modelBytes: 1_049_615_680,
        projectorFilename: nil,
        projectorBytes: 0
    )

    static let vision = Model(
        repoID: "LiquidAI/LFM3-VL-2B-GGUF",
        revision: "7c3b4a43c9023e80bf234fec5e826a3365c8dda8",
        modelFilename: "LFM3-VL-2B-QAD-Q4_0.gguf",
        modelBytes: 1_049_615_648,
        projectorFilename: "mmproj-LFM3-VL-2B-Q8_0.gguf",
        projectorBytes: 203_031_872
    )

    /// Text, image, audio and video in one download. The projector also holds
    /// the audio encoder; image prompts use the same markup as LFM3 VL.
    static let omni = Model(
        repoID: "LiquidAI/LFM3-Omni-2B-GGUF",
        revision: "3d29af2ad166f8299c2d820937e47dc0add20ffc",
        modelFilename: "LFM3-Omni-2B-Q4_0.gguf",
        modelBytes: 1_049_617_920,
        projectorFilename: "mmproj-LFM3-Omni-2B-Q8_0.gguf",
        projectorBytes: 506_842_528
    )

    /// Omni needs llama.cpp b11960 (`build/LFM3OmniNative`), which the build
    /// script ties to the LFM3_OMNI flag. A build switched back to b11938
    /// neither offers nor loads it.
    static var omniRuntimeAvailable: Bool {
        #if LFM3_OMNI
        true
        #else
        false
        #endif
    }

    private static func squashed(_ identity: String) -> String {
        identity.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    static func isFamily(_ identity: String) -> Bool {
        squashed(identity).contains("lfm3")
    }

    static func isOmni(_ identity: String) -> Bool {
        squashed(identity).contains("lfm3omni")
    }

    static func unavailableReason(for identity: String) -> String? {
        if isEnabled, isOmni(identity), !omniRuntimeAvailable {
            return "LFM3-Omni needs the llama.cpp b11960 runtime; this build uses an earlier one."
        }
        guard !isEnabled, isFamily(identity) else { return nil }
        return "LFM3 needs the experimental LFM3 runtime; this build uses the existing llama.cpp runtime."
    }

    /// LFM3 models that take images through mtmd with Liquid's vision markup.
    static func isVision(_ identity: String) -> Bool {
        let id = squashed(identity)
        return id.contains("lfm3vl2b") || id.contains("lfm3omni2b")
    }

    /// Language names from LFM3-Omni's "tts" chat template
    /// (GGUF `tokenizer.chat_template.tts`); other codes pass through.
    static let omniLanguageNames: [String: String] = [
        "ar": "Arabic", "da": "Danish", "de": "German", "el": "Greek", "en": "American English",
        "en-us": "American English", "en-gb": "British English", "fi": "Finnish", "fr": "French",
        "he": "Hebrew", "it": "Italian", "ja": "Japanese", "ko": "Korean", "nl": "Dutch",
        "pl": "Polish", "pt": "Portuguese", "es": "Spanish", "sv": "Swedish", "tr": "Turkish",
        "zh": "Chinese",
    ]

    private static func omniLanguage(_ code: String?) -> String {
        let code = (code?.isEmpty == false ? code! : "en").lowercased()
        return omniLanguageNames[code] ?? code
    }

    /// The model's own "tts" template, rendered here because the app does not
    /// link llama.cpp's common library. Voice is "female" (default) or "male".
    static func speechPrompt(_ text: String, language: String?, voice: String?) -> String {
        let voice = ["female", "male"].contains(voice?.lowercased() ?? "") ? voice!.lowercased() : "female"
        return "<|startoftext|><|im_start|>system\nPerform TTS in \(omniLanguage(language)) using a \(voice) voice.<|im_end|>\n"
            + "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n<think></think><|audio_start|>"
    }

    /// Speech-to-text as on the LFM3-Omni card ("Perform ASR in English."),
    /// with the recording as the user turn.
    static func transcriptionPrompt(marker: String, language: String?) -> String {
        let name = omniLanguage(language) == "American English" ? "English" : omniLanguage(language)
        return "<|im_start|>system\nPerform ASR in \(name).<|im_end|>\n<|im_start|>user\n\(marker)<|im_end|>\n"
            + "<|im_start|>assistant\n<think></think>"
    }

    /// mtmd expands the marker to Liquid's vision-start/image/vision-end
    /// tokens. Lens uses the publisher's non-thinking assistant prefix so a
    /// short image request does not spend its answer budget on reasoning.
    static func visionPrompt(_ prompt: String, marker: String) -> String {
        let content: String
        if prompt.contains(marker) {
            content = prompt
        } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = marker
        } else {
            content = "\(marker)\n\(prompt)"
        }
        return "<|im_start|>user\n\(content)<|im_end|>\n<|im_start|>assistant\n<think></think>"
    }
}
