import SwiftUI

struct UserGuideView: View {
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            // spacing 0: `KSection` is an `InstrumentPanel` now, and panels
            // tile against each other on shared rules. A 20pt gap between them
            // would float each one on the page — the card look the grammar
            // removes. The lead blocks below carry their own vertical padding.
            VStack(spacing: 0) {
                // Intro Section
                VStack(alignment: .leading, spacing: 6) {
                    KCaption(text: "manual")
                    KPageTitle(title: "User Guide", size: 28)
                    KMono(text: "On-device AI studio manual & workflows", size: 12, color: T.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 18)

                // Privacy Note
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundColor(T.accent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: StudioRadius.panel).fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("100% On-Device & Private")
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text("All models run locally. No data leaves this device.")
                            .font(T.sans(11))
                            .foregroundColor(T.ink3)
                    }
                    Spacer()
                }
                .padding(14)
                .kGlass(cornerRadius: StudioRadius.panel, fallbackFill: T.surface)
                .padding(.horizontal, 16)
                .padding(.bottom, 18)

                // 1. Assistant View Section
                KSection(title: "assistant") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Interactive Local Chat")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Engage in direct chats with your chosen reasoning model (e.g. Qwen, Llama). Code blocks are automatically formatted with syntax highlighting.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)
                        
                        visualImage("img_assistant")
                        
                        bulletPoint("Composer Inputs", "Attach images, documents, or repositories. Access saved snip presets from the toolbar.")
                        bulletPoint("Conversation Search", "Filter local chat histories by keywords in real-time.")
                        bulletPoint("Tool Integrations", "Supports local tool-calling like Web Search, with user approvals.")
                    }
                    .padding(14)
                }

                // 2. Image Generation Section
                KSection(title: "image_generation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local Diffusion Models")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Create artwork locally using Stable Diffusion or SDXL-Turbo, designed to operate safely within iOS RAM limits.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        HStack(spacing: 10) {
                            visualImage("img_prompting")
                            visualImage("img_generation")
                        }

                        bulletPoint("Model Profiles", "Select specialized profiles like DreamShaper 8 and configure negative prompts.")
                        bulletPoint("Refining Details", "Configure generation steps. Fast models require only 1–4 steps.")
                    }
                    .padding(14)
                }

                // 3. Lens (Camera) Section
                KSection(title: "camera_&_lens") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Real-Time Code & Vision")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Use the viewfinder to scan source code from screens or whiteboards, or stream continuous descriptive VLM captions.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_lens")

                        bulletPoint("Code Mode (Default)", "Frames and captures code using a high-fidelity OCR pass, sending it directly to the LLM analyzer.")
                        bulletPoint("Visual Mode (VLM)", "Point at anything to generate live text descriptions of objects, screens, or layouts.")
                        bulletPoint("Describe Interval", "Adjust follow-up refresh intervals from 6s to 30s. Manual describes can be triggered at any time.")
                    }
                    .padding(14)
                }

                // 4. Voice Section
                KSection(title: "voice_assistant") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Hands-Free Conversational Loop")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Talk directly with models using robust voice activity detection (VAD) that filters out ambient background noise.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_voice")

                        bulletPoint("Synchronized Audio", "Uses a single synchronized audio session for seamless transitions between listening and speaking.")
                        bulletPoint("Neural TTS Engines", "Select between system voice synthesis and advanced local voices (KittenTTS, Kokoro).")
                    }
                    .padding(14)
                }

                // 5. Models Hub
                KSection(title: "model_management") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Unified Model Library")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("The central hub for downloading models, searching HuggingFace, and tracking local disk space usage.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        bulletPoint("Residency Gates", "Models automatically load and unload dynamically to protect your device from memory-related jetsam kills.")
                        bulletPoint("Disk Management", "Segments total storage sizes per type (Language, Vision, Voice) and allows one-tap cleanups of orphaned files.")
                        bulletPoint("Hugging Face Search", "Find and download any compatible open-source model directly by entering its repository path.")
                    }
                    .padding(14)
                }

                // 6. Local API server
                KSection(title: "API server") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local API server")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Open API server from the sidebar to let compatible clients send requests to a model running on this device.")
                            .font(T.sans(12))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        bulletPoint("Client setup", "Enable the server, choose a downloaded model, then copy the connection URL and API key into your client.")
                        bulletPoint("Local network", "Use a trusted network. Requests require authentication, and the server stops when the app enters the background.")
                    }
                    .padding(14)
                }
            }
            .padding(.bottom, 40)
        }
        .background(StudioPageBackground())
        .navigationBarTitleDisplayMode(.inline)

    }

    @ViewBuilder
    private func visualImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .cornerRadius(StudioRadius.panel)
            .overlay(RoundedRectangle(cornerRadius: StudioRadius.panel).stroke(T.glassBorder, lineWidth: 0.5))
    }

    @ViewBuilder
    private func bulletPoint(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Rectangle().fill(T.accent).frame(width: 4, height: 4)
                KMono(text: title.uppercased(), size: 10, weight: .semibold, color: T.accent)
            }
            Text(desc)
                .font(T.sans(12))
                .foregroundColor(T.ink3)
                .lineSpacing(2)
                .padding(.leading, 10)
        }
    }
}
