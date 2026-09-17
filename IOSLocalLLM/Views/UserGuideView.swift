import SwiftUI

struct UserGuideView: View {
    @Environment(\.koduTheme) private var T
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Intro Section
                VStack(alignment: .leading, spacing: 6) {
                    KCaption(text: "manual")
                    KPageTitle(title: "User Guide", size: 28)
                    KMono(text: "Make OnDevice Core your own", size: 12, color: T.ink3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                // Privacy Note
                HStack(spacing: 12) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 16))
                        .foregroundColor(T.accent)
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(T.accentSoft))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local by default. You choose what connects.")
                            .font(T.sans(14, .semibold))
                            .foregroundColor(T.ink)
                        Text("Downloaded local models run on your device. Cloud models, web tools, sync, and Mac connections are optional and can send content off-device.")
                            .font(T.sans(11.5))
                            .foregroundColor(T.ink3)
                    }
                    Spacer()
                }
                .padding(14)
                .kGlass(cornerRadius: 18, fallbackFill: T.surface)
                .padding(.horizontal, 16)

                // 1. Assistant View Section
                KSection(title: "assistant") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Ask, write, and explore")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Choose a model and start a conversation. Learn about a topic, draft a message, summarize a document, or work through an idea. You can also ask for help with code.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)
                        
                        visualImage("img_assistant")
                        
                        bulletPoint("Bring your own context", "Attach documents or add photos for a compatible vision model. Reuse saved prompts from the composer toolbar.")
                        bulletPoint("Conversation Search", "Filter local chat histories by keywords in real-time.")
                        bulletPoint("Optional tools", "Enable tools when you need them. Web search uses a network connection; review requests before approving them.")
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
                            .font(T.sans(12.5))
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
                        Text("Explore what you see")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Use Lens to describe objects, read text, and explore documents or scenes with a vision model. A separate Code mode helps you capture and understand source code.")
                            .font(T.sans(12.5))
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
                        Text("Talk it through")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Have a conversation with your selected model. Voice shows when it is listening, thinking, or speaking, and lets you interrupt to take another turn.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_voice")

                        bulletPoint("Follow the conversation", "The voice orb responds to speech and changes with each conversation state.")
                        bulletPoint("Choose a voice", "Use a system voice or download a compatible local voice in Models. Adjust playback in Voice settings.")
                    }
                    .padding(14)
                }

                // 5. Models Hub
                KSection(title: "model_management") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Unified Model Library")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Build your collection of chat, vision, voice, and image models. Discover compatible models on Hugging Face, import your own, and manage device storage.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        bulletPoint("Find the right fit", "Device guidance helps you choose models for the memory available. Larger models may need more space and time to respond.")
                        bulletPoint("Disk Management", "Segments total storage sizes per type (Language, Vision, Voice) and allows one-tap cleanups of orphaned files.")
                        bulletPoint("Hugging Face Search", "Find and download any compatible open-source model directly by entering its repository path.")
                    }
                    .padding(14)
                }

                // 6. Mac Bridge Section
                KSection(title: "mac_bridge") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connect your Mac")
                            .font(T.sans(15, .semibold))
                            .foregroundColor(T.ink)
                        
                        Text("Pair with LocalCoderBridge on your Mac. Scan the desktop QR code to establish secure local connection links.")
                            .font(T.sans(12.5))
                            .foregroundColor(T.ink2)
                            .lineSpacing(3)

                        visualImage("img_mac_bridge")

                        bulletPoint("Local connection", "Use your iPhone's supported local models from your paired Mac over your network.")
                        bulletPoint("Visual Inspection", "Streams Mac screenshots, simulator boundaries, and Xcode logs directly to the iOS visual model.")
                    }
                    .padding(14)
                }
            }
            .padding(.bottom, 40)
        }
        .background(LiquidPinkBackdrop())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func visualImage(_ name: String) -> some View {
        Image(name)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(T.glassBorder, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 14, y: 3)
    }

    @ViewBuilder
    private func bulletPoint(_ title: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle().fill(T.accent).frame(width: 4, height: 4)
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
