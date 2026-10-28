import SwiftUI
import OnDeviceUI

/// Presentation only. The host records completion and owns all services.
/// Four short pages in the app's own vocabulary: the icon's ink plate,
/// grouped tiles like the sidebar, mono kickers like the transcript, and the
/// ink primary button. Model facts mirror the catalog entries.
struct OnboardingOnePager: View {
    var onFinish: () -> Void
    @State private var page = 0
    private let lastPage = 3

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                welcome.tag(0)
                runtimes.tag(1)
                largeModels.tag(2)
                studio.tag(3)
            }
            // The system dots float over scrolling content; the ink indicator
            // sits above the button instead. VoiceOver still announces pages.
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background { Color(uiColor: .systemGroupedBackground).ignoresSafeArea() }
            .toolbar {
                if page < lastPage {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { onFinish() } label: { Text(odKey: "Skip") }
                            .accessibilityIdentifier("onboarding.skip")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: ODLayout.pageInset) {
                    HStack(spacing: 6) {
                        ForEach(0...lastPage, id: \.self) { index in
                            Capsule().fill(index == page ? ODPalette.text : ODPalette.line)
                                .frame(width: index == page ? 18 : 6, height: 6)
                        }
                    }
                    .animation(.snappy, value: page)
                    .accessibilityHidden(true)
                    Button {
                        if page < lastPage { withAnimation(.snappy) { page += 1 } } else { onFinish() }
                    } label: {
                        Text(odKey: page < lastPage ? "Continue" : "Get started")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .odInkProminent()
                    .accessibilityIdentifier("onboarding.primary")
                }
                .padding(ODLayout.pageInset)
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        pageScroll {
            ODBrandTile(size: 96, motion: .intro)
                .padding(.bottom, ODLayout.elementGap)
            VStack(alignment: .leading, spacing: ODLayout.labelGap) {
                Text(verbatim: "Token AI").font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(odKey: "Your ideas. Your device.").font(.title2.weight(.semibold))
                Text(odKey: "Chat, see, speak and create with models that run on your iPhone.")
                    .font(.body).foregroundStyle(ODPalette.secondary)
            }
            VStack(spacing: 0) {
                fact("iphone", "On device")
                OnboardingDivider()
                fact("wifi.slash", "Offline after download")
                OnboardingDivider()
                fact("person.crop.circle.badge.checkmark", "No account needed")
            }
            .card()
        }
    }

    private var runtimes: some View {
        pageScroll {
            header(kicker: "RUNTIMES", title: "Every major model format",
                   detail: "Run Core AI packs, MLX checkpoints and GGUF files side by side. Download from Hugging Face or import your own.")
            VStack(spacing: ODLayout.elementGap) {
                runtime("Core AI", symbol: "cpu", detail: "Apple’s on-device engine for packs from the Core AI model zoo.")
                runtime("MLX", symbol: "square.stack.3d.up", detail: "Apple-silicon arrays for MLX checkpoints from Hugging Face.")
                runtime("GGUF", symbol: "shippingbox", detail: "llama.cpp for quantized GGUF models, including your own files.")
            }
        }
    }

    private var largeModels: some View {
        pageScroll {
            header(kicker: "PREVIEW", title: "35B models on iPhone",
                   detail: "Mixture-of-experts models activate about 3B parameters per token. Token AI streams the rest from storage, so a 35B model runs in a few gigabytes of memory.")
            VStack(spacing: ODLayout.elementGap) {
                model("Edge0-35B A3B", tag: "Preview",
                      detail: "Reasoning with a visible thinking trace. 19.6 GB download.")
                model("MiniCPM-V 4.7 35B A3B", tag: "Experimental",
                      detail: "Image understanding with experts streamed from storage. Needs 12 GB of RAM and about 35 GB free.")
            }
            Text(odKey: "Both are large downloads, and performance varies by device.")
                .font(.footnote).foregroundStyle(ODPalette.secondary)
        }
    }

    private var studio: some View {
        pageScroll {
            header(kicker: "STUDIO", title: "One studio, every tool",
                   detail: "Every workspace uses the same models on your iPhone.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: ODLayout.elementGap),
                                GridItem(.flexible(), spacing: ODLayout.elementGap)],
                      spacing: ODLayout.elementGap) {
                tile("Chat", symbol: "bubble.left", detail: "Write, ask and work with files.")
                tile("Lens", symbol: "camera", detail: "Ask, translate, scan or solve.")
                tile("Voice", symbol: "waveform", detail: "Talk through an idea hands-free.")
                tile("Image studio", symbol: "photo", detail: "Create images on device.")
                tile("Code", symbol: "chevron.left.forwardslash.chevron.right", detail: "Edit and review repositories.")
                tile("API server", symbol: "network", detail: "Serve local models to apps on your network.")
                tile("Classifiers", symbol: "checklist", detail: "Run on-device classifiers.")
                tile("Models", symbol: "cube", detail: "Download, import and manage.")
            }
            Text(odKey: "Local models process your content on this device. Downloads, optional web access, Apple Private Cloud Compute, and paired Mac tools use the network when you choose them. You control these features in Settings.")
                .font(.footnote).foregroundStyle(ODPalette.secondary)
        }
    }

    // MARK: Parts

    private func pageScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODLayout.groupGap) { content() }
                .padding(.horizontal, ODLayout.pageInset)
                .padding(.vertical, ODLayout.largeGap)
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func header(kicker: String, title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ODLayout.labelGap) {
            Text(odKey: kicker)
                .font(.system(.caption2, design: .monospaced, weight: .semibold))
                .tracking(1.4).foregroundStyle(ODPalette.secondary)
            Text(odKey: title).font(.largeTitle.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(odKey: detail).font(.body).foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fact(_ symbol: String, _ title: String) -> some View {
        Label { Text(odKey: title).font(.body) } icon: {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 28)
        }
        .frame(maxWidth: .infinity, minHeight: ODLayout.rowMinimumHeight, alignment: .leading)
        .padding(.horizontal, ODLayout.pageInset)
    }

    private func runtime(_ name: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: ODLayout.labelGap) {
            InkPlate(symbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name).font(.headline)
                Text(odKey: detail).font(.subheadline).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(ODLayout.labelGap)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func model(_ name: String, tag: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            HStack(spacing: ODLayout.elementGap) {
                // The same live stream used for model activity across the app.
                ODBrandMark(height: 12, motion: .live).foregroundStyle(ODPalette.text)
                Spacer(minLength: 0)
                Text(odKey: tag).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(ODPalette.input, in: Capsule())
            }
            Text(verbatim: name).font(.title3.weight(.bold))
            Text(odKey: detail).font(.subheadline).foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ODLayout.pageInset)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func tile(_ title: String, symbol: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: ODLayout.unit) {
            Image(systemName: symbol).font(.body.weight(.medium)).frame(height: 24)
                .accessibilityHidden(true)
            Text(odKey: title).font(.subheadline.weight(.semibold))
            Text(odKey: detail).font(.caption).foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(ODLayout.labelGap)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// White SF Symbol on the app icon's ink plate, matching the model badges.
private struct InkPlate: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.title3.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(Color(red: 0.043, green: 0.047, blue: 0.063), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }
}

private struct OnboardingDivider: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle().fill(ODPalette.line)
            .frame(height: ODLayout.hairline(displayScale: displayScale))
            .padding(.leading, ODLayout.pageInset + 40)
    }
}

private extension View {
    /// The grouped surface used by sidebar tiles and Settings cards.
    func card() -> some View {
        background(Color(uiColor: .secondarySystemGroupedBackground),
                   in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
