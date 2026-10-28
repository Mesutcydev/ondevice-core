import Foundation

// MARK: - LegalDocuments
// Centralised source of truth for every legal text shown in the app.
// Edit these strings to update the Privacy Policy, license notice, Disclaimer,
// and Attributions.
//
// IMPORTANT before distributing a modified build:
//   • Update the public URLs below to point to your fork.
//   • Have a real lawyer review these texts for your jurisdiction.
//   • The texts below are template-quality, not legal advice.

enum LegalDocuments {

    // MARK: - Versioning
    // Bump this whenever any legal text materially changes. Existing users
    // will be re-prompted to accept on app launch.
    static let currentVersion = 8

    // MARK: - Public URLs
    static let privacyPolicyURL = "https://mesut.uk/apps/token/privacy"
    static let eulaURL          = "https://github.com/Mesutcydev/ios-local-llm/blob/main/LICENSE"
    static let supportURL       = "https://mesut.uk/apps/token/support"

    // MARK: - Privacy Policy

    static let privacyPolicy = """
    # Privacy Policy

    **Last updated:** \(currentVersionDate)

    Token AI runs AI locally by default. The project operates no account, analytics, advertising, or inference backend and does not sell personal data. Optional network features send requests to providers, which may collect and retain them as described below.

    ## 1. Project-operated collection
    The project does not operate a service that receives the following content. Optional providers have separate collection and retention practices described below.
    - We do **not** collect images, video, or photos captured by the camera.
    - We do **not** collect any text you enter, including chat conversations with the on-device assistant.
    - We do **not** collect analytics, telemetry, crash reports, device identifiers, advertising identifiers, or any other usage data.
    - The project operates no cookie or web-beacon tracking service. Optional providers and websites apply their own privacy practices.
    - We do **not** sell or rent your data. Providers receive only the information needed for the optional network features you choose below.

    ## 2. What stays on your device
    - **Camera content** is processed locally. Captures, selected attachments, and analysis history may be retained locally by the features you use.
    - **Photos and attachments** you select can be retained locally with your conversations or analysis history. Shared content is staged in the app's protected App Group container so the app can receive it when opened.
    - **Chat conversations** with the Assistant are stored locally in the app's sandbox. You can delete them at any time. The app doesn't sync them to iCloud or any other service; like other app data, they can be included in your device backups. Apple Private Cloud is described below.
    - **Downloaded AI models** are stored in the app's sandbox and execute locally. Model downloads require network access.
    - **Parental controls** store a salted derived parent PIN, restrictions, and retry limits in device-only Keychain storage. They are not transmitted and are preserved when app data is cleared. Changing or removing controls requires the parent PIN.
    - **Generated images** are stored locally for viewing and sharing. Copies exported to Photos or another app remain under that destination's control.

    ## 3. Network usage
    The app connects to the network only for explicit features:
    - **Model search and download:** Hugging Face receives the request. A saved Hugging Face token is included only when required for a gated repository.
    - **Web search and fetch:** The configured provider receives a search query, request metadata, and your provider credential where configured. An assistant-proposed query can include conversation information. “Ask Every Time” requests approval; “Always Allow” permits later requests without separate approval. Fetched websites receive their URL request and network metadata.
    - **Mac Bridge and Local API Server:** When enabled, paired clients communicate with the app over your local network.
    - **Apple Private Cloud:** In builds with Apple's entitlement, selecting this model requires a separate privacy consent. The request's prompt and included conversation context are sent to Apple's Private Cloud Compute service for inference under Apple's privacy practices. This is remote inference, and local models do not silently switch to it.
    - **API providers:** After you configure and select an API model and accept its separate disclosure, the selected endpoint receives included conversation text, system instructions, tool results, attached file excerpts, and supported images. The provider and its model operators apply their own privacy, retention, and billing terms. API keys stay in device-only Keychain storage. Catalog refresh sends credentials and request metadata without conversation content; saving settings and opening the picker make no request. Local models never silently switch to an API provider. Custom HTTP endpoints on trusted private networks are unencrypted in transit.
    - **External documentation and links:** These open only after your action.
    - **GitHub repository tools:** Off by default. After you connect GitHub, enable tools and select a repository/branch, GitHub receives authentication, request metadata, scoped file requests and approved commits, branches, pull requests or reverts. Credentials stay in device-only Keychain and never enter chat model requests. File edits remain a protected conversation draft until review. An API model receives included repository excerpts/tool results under its separate disclosure. Disconnecting deletes the saved token and turns off GitHub tools.

    There is no Token AI telemetry channel, remote configuration service, analytics SDK, or advertising SDK.

    Search providers can retain requests. Brave Search API documents query retention up to 90 days unless a qualifying enterprise zero-retention arrangement applies. Tavily describes query collection, potential service improvement use, and limited sharing with search index providers. Exa and DuckDuckGo apply their published policies. SearXNG and custom endpoints apply the selected operator's practices. Provider policy links are in the public Privacy Policy; Token AI cannot promise zero retention for these optional features.

    ## 4. Permissions we request
    - **Camera:** Required to capture frames for live analysis. Disable in iOS Settings any time; the app will continue to work with imported photos only.
    - **Photo Library:** Optional. Only requested when you tap the photo picker. The app accesses only photos you explicitly select.
    - **Microphone and speech recognition:** Used when you start a voice conversation or dictation. Local speech engines process audio on the device.
    - **Local network:** Used when you enable the Local API Server or paired Mac bridge, or choose a custom API endpoint on your private network.
    - **Save to Photos:** Used when you choose to save a generated image.

    ## 5. Children
    The app is not directed at children under 13. The project operates no personal-data backend, but optional features send requests to providers under their privacy terms. A parent can set a PIN to restrict image generation in the app. Parental controls do not verify age and do not replace iOS Screen Time. Separate app safeguards add chat safety instructions and image-request phrase checks locally; these are not reliable classifiers of every request or generated image. Contact us via the Support link for questions.

    ## 6. Third-party AI models
    The app uses third-party AI models that run on your device. We are not the authors of these models. Each model's license, source repository, and citation is shown in **Settings → Legal → Attributions**. A model may be open source, source-available, community-licensed, or restricted to research use; review its terms before downloading or using it.

    ## 7. Hugging Face downloads
    When you tap "download" on a Hugging Face model, your device makes HTTPS requests to `huggingface.co`. We do not control Hugging Face. Their privacy policy and terms of service apply. If you save a Hugging Face token for a gated repository, the app stores it in the Keychain and sends it to Hugging Face for authorized requests; Token AI does not receive it.

    ## 8. Apple frameworks
    The app uses Apple-provided iOS frameworks (Vision, Speech, Core ML, MetricKit, ActivityKit). These frameworks operate under Apple's privacy practices. **Speech recognition is forced on-device** wherever the device supports it (recent iPhones).

    ## 9. MetricKit diagnostics
    iOS periodically sends MetricKit reports (crash, hang, CPU usage) to the app for the user's own diagnostic use. These reports stay on the device — we do not collect or transmit them. You can view and delete them in **Settings → Diagnostics**.

    ## 10. Network-activity indicator
    A live indicator in the assistant tab reports requests made through the app's monitored networking layer. It is a useful diagnostic, not a system-wide packet monitor.

    ## 11. Data retention
    Conversations are stored in the app sandbox with file protection (`completeFileProtectionUnlessOpen`). Settings offers local data-clearing controls. The parent PIN and restrictions are deliberately preserved by data clearing. Uninstalling removes the app sandbox, but Keychain records can survive; remove parental controls using the parent PIN before uninstalling to remove that record. Exported content and device backups require deletion in their respective destinations.

    ## 12. Your rights
    The project operates no personal-data backend. Local content is controlled on your device. For information transmitted by optional features, contact the receiving provider about its access, correction, and deletion procedures. Contact us via the Support link for questions about the app.

    ## 13. Changes
    If we change this policy we will update the "Last updated" date and re-prompt for acceptance inside the app.

    ## 14. Contact
    Questions: see Settings → Legal → Support.
    """

    // MARK: - Open-source license and safety notice

    static let eula = """
    # Open-Source License and Safety Notice

    **Last updated:** \(currentVersionDate)

    This source distribution contains original open-source software and separately licensed third-party material. This notice summarizes licenses and important safety information; it does not add copyright restrictions to the MIT-licensed portions of the app.

    ## 1. Token AI license
    Token AI is an independent modified distribution derived from the **iOS Local LLM** open-source project. The original project code, this distribution's modifications, and the documentation are available under the **MIT License**. Subject to that license, you may use, copy, modify, merge, publish, distribute, sublicense, and sell copies.

    The MIT copyright and permission notice must be included in copies or substantial portions of the software. “Token AI” is this distribution's product identity; “iOS Local LLM” remains the upstream project attribution. iOS and related names are Apple Inc. trademarks. Neither project is affiliated with or endorsed by Apple or any compatibility provider.

    ## 2. Third-party components and models
    Token AI includes or downloads components that are separate works under their own terms. Those terms are not replaced by the Token AI MIT License.

    A model may be open source, source-available, community-licensed, non-commercial, or research-only. **Review the license shown by the model source before downloading, using, modifying, or redistributing it.** Apple FastVLM model weights, for example, are licensed for research purposes only and are not part of the MIT-licensed source distribution.

    ## 3. AI-generated content
    The app runs third-party models locally and, when available and explicitly selected, Apple's optional Private Cloud model remotely. Outputs are generated by statistical models and may be:
    - Factually incorrect, outdated, fabricated, or misleading ("hallucinations").
    - Biased, offensive, or unsafe.
    - Inappropriate or harmful in your context (medical, legal, financial, safety-critical, security, or other regulated domains).
    - Subject to third-party copyright or other intellectual-property rights.

    **You alone are responsible for verifying any AI output before relying on it.** Do not use AI output to make any decision that could affect a person's health, safety, finances, legal rights, or employment, without independent verification by a qualified human professional. **Do not run AI-generated code in production, against real data, or in any environment you cannot afford to lose, without thorough independent review and testing.**

    ## 4. Device safety
    Running large machine-learning models on a mobile device is computationally intensive and may:
    - Cause the device to **become warm or hot to the touch**.
    - **Reduce battery life** during use and accelerate long-term battery wear.
    - Trigger iOS thermal throttling, which the app handles automatically by reducing output length or pausing generation.
    - In extreme cases, cause the operating system to terminate the app to protect the device.

    These are intrinsic properties of on-device AI inference. Do not use the app where device heat could cause harm, and stop using it if the device becomes uncomfortably hot.

    ## 5. Camera, microphone, and image use
    Some features process camera frames, microphone audio, or photos you select. Local engines process these on the device. Optional API providers, web search and Apple Private Cloud can send the content described in the Privacy Policy after your action and consent. These choices do not remove your responsibility to obtain any required consent from people whose content you capture.

    ## 6. Network usage and privacy
    The app makes outbound requests for model search/downloads, enabled web search, the local API and paired bridge, optional API providers after selection and consent, Apple Private Cloud after its separate consent in entitled builds, and links you choose to open. Each provider applies its own privacy terms. Downloaded models retain their own licenses.

    ## 7. No warranty
    IOS_LOCAL_LLM, THIRD-PARTY COMPONENTS, MODELS, AND AI OUTPUTS ARE PROVIDED **"AS IS"**, WITHOUT WARRANTY OF ANY KIND, TO THE MAXIMUM EXTENT PERMITTED BY THEIR APPLICABLE LICENSES AND BY LAW. The complete MIT warranty disclaimer is included with the source distribution.

    **By continuing, you confirm that you have read this notice and understand that model licenses and safety information require separate attention.**
    """

    // MARK: - User disclaimer (shown to users on first use of AI features)

    static let aiDisclaimer = """
    # AI Output Disclaimer

    Token AI runs **third-party artificial intelligence models entirely on your device** to analyse images, generate text, extract code, review code, transcribe speech, and synthesize speech. A model's availability in the catalog does not mean it is open source. Read its license and understand the following before relying on any output.

    ## 1. AI output is generated by statistics, not understanding
    Outputs are produced by neural networks that predict the next token based on patterns in their training data. They do not "understand" your input, do not have access to real-time information, and do not verify their own answers. They can and routinely will produce:
    - **Hallucinations** — confidently stated facts, citations, function names, library APIs, or library versions that do not exist.
    - **Bugs and security holes** — code that compiles or appears reasonable but contains logic errors, race conditions, injection vulnerabilities, exposed secrets, or licence violations.
    - **Inaccurate OCR / image analysis** — characters misread, code mis-transcribed, contents of an image mis-described.
    - **Biased, offensive, or unsafe content** — reflecting biases in the training data.
    - **Out-of-date information** — the models do not have current internet access and may be months or years behind.

    **Always independently verify any AI output before relying on it.**

    ## 2. Do not run AI-generated code blindly
    Treat generated code as a draft, not a finished product. Before running it:
    - Read it line by line.
    - Run it in a sandboxed environment, not against production data or critical infrastructure.
    - Test it with edge cases and adversarial inputs.
    - Review any shell commands, file operations, network calls, deletes, or destructive actions in particular.
    - Check that any libraries, APIs, and CLI flags it uses actually exist and behave the way the model claims.

    **We are not responsible for any data loss, security breach, system damage, financial loss, or other harm caused by running AI-generated code or commands.**

    ## 3. Not a substitute for a professional
    The app does **not** provide and must not be relied on for:
    - **Medical** advice, diagnosis, or treatment.
    - **Legal** advice or interpretation.
    - **Financial**, tax, or investment advice.
    - **Engineering, safety-critical, or life-critical** decisions (aviation, automotive, industrial control, structural, electrical, etc.).
    - **Mental-health, crisis, or self-harm** support. If you are in crisis, contact your local emergency number or a qualified crisis service.

    Consult a qualified human professional for any decision in these areas.

    ## 4. Camera, microphone, and image processing
    When you use the camera or import a photo, the app analyses pixels with on-device AI. **You are responsible for ensuring you have the right to capture and analyse the subject matter** (consent of people in frame, licence to scan documents, etc.). The app processes everything locally and does not transmit images, but local processing does not relieve you of consent obligations under your local law.

    ## 5. You are responsible for what you do with the output
    You — not the app, not the model authors, not us — are responsible for any decision you make or action you take based on AI output, including but not limited to:
    - Code you commit, ship, or run.
    - Decisions you make based on a described image.
    - Actions taken in response to TTS / spoken output.
    - Anything you share with another person.

    ## 6. On-device privacy (not anonymity)
    AI inference uses your selected runtime. Downloaded models run on your device. The app operates no telemetry or inference backend. Optional network features can transmit conversation information or other data as described in the Privacy Policy:
    - Searches and downloads from `huggingface.co` when you explicitly request them; gated repositories may include a token you saved.
    - Web search and fetch when you enable them. Assistant-proposed queries can include conversation information, and providers can retain requests.
    - Mac Bridge or Local API communication on your local network when enabled.
    - Apple Private Cloud inference only in authorized builds, after you select it and consent to sending the prompt and included conversation context to Apple.
    - API model inference after explicit selection and provider consent, and model catalog requests when you choose Refresh models.
    - External documentation and links when you choose them.

    A live indicator reports requests made through the app's monitored networking layer; it is not a system-wide packet monitor. Local inference avoids sending the generation request to a cloud model, but does **not** make your use anonymous to your network provider, your device-management policies, or anyone with physical access to your unlocked device.

    ## 7. Device thermals and battery
    Running large models is computationally intensive. Your device will warm up, occasionally significantly, and battery will drain faster than during normal use. iOS may throttle performance to protect the device, and we apply additional protections (token-cap reduction, generation refusal, mid-stream halts) when iOS reports a "serious" or "critical" thermal state. **Do not place the device on flammable surfaces, do not charge in an enclosed space while running heavy generation, and stop using the app if the device becomes uncomfortably hot.**

    ## 8. Bias and content
    The underlying models can reflect biases, errors, and offensive content in their training data. Token AI adds safety instructions to chat requests and checks image requests for some explicit-content phrases. Image models that support negative prompts also receive additional exclusions. These safeguards are not comprehensive prompt or image-output classifiers, and inappropriate output remains possible. Use **Report content concern** in an image's or response's action menu to open support; nothing is attached or sent automatically. Stop generation and delete content that concerns you.

    ## 9. Voice / text-to-speech outputs
    Spoken output is synthesized from text by a TTS model. Tone and emphasis may differ from what a human reader would convey. Do not rely on voice mode for time-critical or safety-critical instructions, and do not assume the spoken version captures every detail of the written reply.

    ## 10. Third-party model licences
    Each model you download from Hugging Face is governed by its own licence. Some licences restrict commercial use or impose usage conditions. **It is your responsibility to read and comply with each licence.** Attribution, source URLs, and licence summaries are available in **Settings → Legal → Attributions**.

    **By tapping "I Understand", you confirm that you have read this disclaimer and accept full responsibility for how you use the app and AI output.**
    """

    // MARK: - Device-safety acknowledgement
    // Surfaced on first launch alongside the EULA and AI disclaimer so users
    // see the thermal/battery realities of on-device AI up front.

    static let deviceSafetyNotice = """
    # Device Safety Notice

    On-device AI inference is computationally intensive. By using Token AI you acknowledge and accept the following.

    ## What to expect
    - **Heat** — your device will become warm, sometimes hot, during model loading and long replies. This is normal for sustained GPU/Neural-Engine work and is the same effect you'd see from a long gaming session or a long video-call.
    - **Battery drain** — battery percentage will drop faster than during normal use. Heavy daily use will also accelerate long-term battery wear, the same as other intensive apps.
    - **Background termination** — iOS may suspend or terminate the app to recover memory or thermal headroom, especially on older devices or when many apps are running.
    - **Network usage** — model downloads can be several gigabytes; use Wi-Fi. Optional web search, local-network features, and authorized Apple Private Cloud builds also use the network as described in the Privacy Policy.

    ## What we do to protect your device
    - **Thermal-aware token caps** — when iOS reports the device is "warm," we shorten replies. When "hot," we pause generation and tell you.
    - **Memory-warning halts** — if iOS signals memory pressure mid-reply, we stop generation instead of risking a hard crash.
    - **Auto-tier defaults** — on first launch we pick a model that comfortably fits this device's RAM.
    - **Storage cap** — model downloads are limited to the device's free space; the OS itself prevents downloads that would fill the disk.

    ## What you should do
    - **Take breaks** during long sessions, especially on older devices. Let the phone cool.
    - **Do not place the device on flammable materials** while running heavy generation.
    - **Do not run heavy generation while charging in a hot, enclosed space** (e.g. under bedding).
    - **Stop using the app** if the device becomes uncomfortably hot or behaves strangely.
    - **Charge with an Apple-certified cable and adapter** to avoid charging-related thermal issues unrelated to the app.

    These are intrinsic properties of on-device machine learning, not defects of Token AI. By continuing you accept that we are not liable for normal thermal output, normal battery drain, or accelerated battery wear consistent with intensive use.
    """

    // MARK: - Attributions

    /// Each Attribution describes a single third-party component we use,
    /// its source, and its license. Shown in Settings → Legal → Attributions.
    static let attributions: [Attribution] = [

        // ── On-device LLMs ───────────────────────────────────────────────────
        Attribution(
            name: "Llama 3.1",
            author: "Meta Platforms, Inc. / mlx-community",
            license: "Llama 3.1 Community License",
            licenseURL: "https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
            paperURL: nil,
            note: "Built with Llama. Llama 3.1 is licensed under the Llama 3.1 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved. Use is subject to Meta's Acceptable Use Policy and additional commercial terms.",
            category: "Language Model"
        ),
        Attribution(
            name: "Llama 3.2 (text models)",
            author: "Meta Platforms, Inc. / mlx-community",
            license: "Llama 3.2 Community License",
            licenseURL: "https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct/blob/main/LICENSE.txt",
            sourceURL: "https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit",
            paperURL: nil,
            note: "Built with Llama. Llama 3.2 is licensed under the Llama 3.2 Community License, Copyright © Meta Platforms, Inc. All Rights Reserved. Use is subject to Meta's Acceptable Use Policy and additional commercial terms.",
            category: "Language Model"
        ),
        Attribution(
            name: "LFM 2.5",
            author: "Liquid AI, Inc.",
            license: "LFM Open License v1.0",
            licenseURL: "https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/LiquidAI",
            paperURL: nil,
            note: "Available as optional text, vision, and audio models. This is a custom license with a commercial-use revenue threshold; it is not Apache-2.0. The publisher and users must satisfy the terms applying to their use.",
            category: "Language Model"
        ),
        Attribution(
            name: "LFM3",
            author: "Liquid AI, Inc.",
            license: "LFM Open License v1.0",
            licenseURL: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF/blob/b3f2ae5d73cd3c91bf40e8ba752c648aa05dffdf/LICENSE",
            sourceURL: "https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF",
            paperURL: nil,
            note: "Optional experimental text and image models. The license includes a commercial-use revenue threshold; use is subject to Liquid AI's terms.",
            category: "Language Model"
        ),
        Attribution(
            name: "Qwen3-4B (mlx-community 4-bit)",
            author: "Alibaba Cloud / Tongyi Lab",
            license: "Apache-2.0",
            licenseURL: "https://github.com/QwenLM/Qwen3/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/mlx-community/Qwen3-4B-4bit",
            paperURL: "https://arxiv.org/abs/2502.12119",
            note: "Available for on-device conversations in Assistant. Qwen3 source and weights are published under Apache-2.0; verify the selected model repository before redistribution.",
            category: "Language Model"
        ),
        Attribution(
            name: "Qwen2-0.5B (FastVLM LLM backbone)",
            author: "Alibaba Cloud / Tongyi Lab",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct/blob/main/LICENSE",
            sourceURL: "https://huggingface.co/Qwen/Qwen2-0.5B-Instruct",
            paperURL: "https://arxiv.org/abs/2407.10671",
            note: "Used as the language model inside the FastVLM pipeline.",
            category: "Language Model"
        ),

        // ── Vision–Language ──────────────────────────────────────────────────
        Attribution(
            name: "FastVLM sample implementation",
            author: "Apple Inc.",
            license: "Apple Sample Code License",
            licenseURL: "https://github.com/apple/ml-fastvlm/blob/main/LICENSE",
            sourceURL: "https://github.com/apple/ml-fastvlm",
            paperURL: "https://arxiv.org/abs/2412.13303",
            note: "Adapted vision encoder and projector sample code. FastVLM model weights are separate and use Apple's research model license.",
            category: "Vision–Language"
        ),
        Attribution(
            name: "FastVLM model weights (not included)",
            author: "Apple Inc.",
            license: "Apple Machine Learning Research Model License",
            licenseURL: "https://github.com/apple/ml-fastvlm/blob/main/LICENSE_MODEL",
            sourceURL: "https://github.com/apple/ml-fastvlm",
            paperURL: "https://arxiv.org/abs/2412.13303",
            note: "Optional research-licensed model weights are not distributed in this source repository. Review LICENSE_MODEL before downloading or using them.",
            category: "Vision–Language"
        ),

        // ── Image generation ─────────────────────────────────────────────────
        Attribution(
            name: "SD Turbo / SDXL Turbo",
            author: "Stability AI",
            license: "Stability AI Community License",
            licenseURL: "https://huggingface.co/stabilityai/sd-turbo/blob/b261bac6fd2cf515557d5d0707481eafa0485ec2/LICENSE.md",
            sourceURL: "https://huggingface.co/stabilityai",
            paperURL: nil,
            note: "Powered by Stability AI. Optional image-generation models. Commercial use requires registration and satisfaction of the license's revenue conditions, or a separate license from Stability AI. Other image models have their own licenses.",
            category: "Image Generation"
        ),

        // ── Text-to-speech ───────────────────────────────────────────────────
        Attribution(
            name: "KittenTTS (CoreML)",
            author: "Alex Weng",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/alexwengg/kittentts-coreml",
            sourceURL: "https://huggingface.co/alexwengg/kittentts-coreml",
            paperURL: nil,
            note: "On-device text-to-speech model. Based on the Kokoro architecture.",
            category: "Text-to-Speech"
        ),
        Attribution(
            name: "Kokoro-82M",
            author: "hexgrad",
            license: "Apache-2.0",
            licenseURL: "https://huggingface.co/hexgrad/Kokoro-82M",
            sourceURL: "https://huggingface.co/hexgrad/Kokoro-82M",
            paperURL: nil,
            note: "Experimental on-device TTS engine.",
            category: "Text-to-Speech"
        ),

        // ── Frameworks ───────────────────────────────────────────────────────
        Attribution(
            name: "MLX Swift (PrismML fork)",
            author: "Apple Inc. / PrismML contributors",
            license: "MIT",
            licenseURL: "https://github.com/PrismML-Eng/mlx-swift/blob/main/LICENSE",
            sourceURL: "https://github.com/PrismML-Eng/mlx-swift",
            paperURL: nil,
            note: "Pinned fork of Apple's Swift API for MLX, used for on-device inference and required one-bit kernels.",
            category: "Framework"
        ),
        Attribution(
            name: "MLX Swift LM",
            author: "MLX contributors",
            license: "MIT",
            licenseURL: "https://github.com/ml-explore/mlx-swift-lm/blob/main/LICENSE",
            sourceURL: "https://github.com/ml-explore/mlx-swift-lm",
            paperURL: nil,
            note: "Provides MLXLLM, MLXVLM, and MLXLMCommon model factories.",
            category: "Framework"
        ),
        Attribution(
            name: "Swift Transformers",
            author: "Hugging Face",
            license: "Apache-2.0",
            licenseURL: "https://github.com/huggingface/swift-transformers/blob/main/LICENSE",
            sourceURL: "https://github.com/huggingface/swift-transformers",
            paperURL: nil,
            note: "Tokenizers and Hub utilities used by mlx-swift-examples.",
            category: "Framework"
        ),
        Attribution(
            name: "thinking-orbs",
            author: "Jakub Antalik",
            license: "MIT",
            licenseURL: "https://github.com/Jakubantalik/thinking-orbs/blob/main/LICENSE",
            sourceURL: "https://github.com/Jakubantalik/thinking-orbs",
            paperURL: nil,
            note: "Dotted state animations adapted for the native Voice Mode canvas.",
            category: "Framework"
        ),
        Attribution(
            name: "Apple Core ML & Vision",
            author: "Apple Inc.",
            license: "Apple SDK License",
            licenseURL: "https://developer.apple.com/support/terms/",
            sourceURL: "https://developer.apple.com/documentation/coreml",
            paperURL: nil,
            note: "iOS frameworks for on-device ML inference, OCR (VNRecognizeTextRequest), and image processing.",
            category: "Framework"
        ),

        // ── Datasets / Catalogues ────────────────────────────────────────────
        Attribution(
            name: "Hugging Face Hub",
            author: "Hugging Face, Inc.",
            license: "Hub Terms of Service",
            licenseURL: "https://huggingface.co/terms-of-service",
            sourceURL: "https://huggingface.co",
            paperURL: nil,
            note: "All AI models are downloaded from huggingface.co at the user's explicit request.",
            category: "Service"
        ),
    ]

    // MARK: - Helpers

    private static var currentVersionDate: String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date(timeIntervalSince1970: 1_792_972_800)) // 2026-10-26
    }
}

// MARK: - Attribution

struct Attribution: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let author: String
    let license: String
    let licenseURL: String?
    let sourceURL: String?
    let paperURL: String?
    let note: String
    let category: String
}
