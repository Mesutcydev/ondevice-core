import SwiftUI

// MARK: - KCapabilityPill
//
// Small capsule rendered next to a model name on catalog rows.
// Consumes the universal `ModelCapability` semantic colors but
// wraps them in a Liquid Glass surface (translucent fill + hairline
// border) so they read as part of the Kodu visual system rather
// than flat-bright chips.
//
// Usage:
//   KCapabilityPill(.vision)
//   KCapabilityPill(.thinking, size: .compact)

struct KCapabilityPill: View {

    enum Size { case standard, compact }

    let capability: ModelCapability
    var size: Size = .standard

    @Environment(\.koduTheme) private var T

    var body: some View {
        // Studio: capabilities read as quiet mono tags on a whisper fill —
        // the semantic hue survives as a small leading dot only, so a card
        // never becomes a rainbow of bordered capsules.
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: StudioRadius.glyph, style: .continuous)
                .fill(capability.tint)
                .frame(width: 4, height: 4)
            Text(capability.label.lowercased())
                .font(T.mono(textSize))
                .tracking(0.2)
        }
        .foregroundColor(T.studio.ink2)
        .padding(.horizontal, hPad)
        .padding(.vertical, vPad)
        .background(
            RoundedRectangle(cornerRadius: StudioRadius.chip, style: .continuous)
                .fill(T.studio.fillActive)
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(capability.label)
    }

    // MARK: - Size knobs

    private var textSize: CGFloat  { size == .standard ? 10 : 9 }
    private var hPad: CGFloat      { size == .standard ? 8 : 6 }
    private var vPad: CGFloat      { size == .standard ? 3.5 : 2.5 }
}

// MARK: - KCapabilityPillRow
//
// Wrapping row for a list of capabilities. Sorts them into the visual
// order matching the design: status markers first (recommended → best
// → new), capability markers next, then the gated lock last.

struct KCapabilityPillRow: View {
    let capabilities: [ModelCapability]
    var size: KCapabilityPill.Size = .standard

    var body: some View {
        let sorted = sortForDisplay(capabilities)
        if sorted.isEmpty {
            EmptyView()
        } else {
            KFlowLayout(horizontalSpacing: 6, verticalSpacing: 5) {
                ForEach(sorted, id: \.rawValue) { cap in
                    KCapabilityPill(capability: cap, size: size)
                }
            }
        }
    }

    private func sortForDisplay(_ caps: [ModelCapability]) -> [ModelCapability] {
        let order: [ModelCapability] = [.recommended, .best, .newRelease,
                                        .vision, .thinking, .tools, .coder,
                                        .fast, .multilingual, .gated]
        let seen = Set(caps)
        return order.filter { seen.contains($0) }
    }
}

// MARK: - KVendorThumb
//
// Rounded-square thumbnail tile that identifies the model publisher.
// Renders procedurally (gradient + monogram or SF Symbol) — no asset
// catalog dependency. The tile takes its colors from `ModelVendor.gradient`
// so the visual remains tied to vendor identity regardless of light/
// dark theme.
//
// Sizes:
//   • `.row`  — 38pt, used in catalog list rows
//   • `.card` — 48pt, used in onboarding cards
//   • `.hero` — 64pt, used in model-detail headers

struct KVendorThumb: View {

    enum Size { case row, card, hero
        var px: CGFloat {
            switch self {
            case .row: return 38
            case .card: return 48
            case .hero: return 64
            }
        }
    }

    let vendor: ModelVendor
    var size: Size = .row

    @Environment(\.koduTheme) private var T

    var body: some View {
        ZStack {
            // Flat neutral fill — vendor gradients were retired with the
            // Studio reskin; identity comes from the monogram, not color.
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(T.studio.fillActive)

            // Mark — SF Symbol when the vendor has one (Apple), monogram
            // otherwise. Emojis (HF) render through Text just fine.
            if let symbol = vendor.systemSymbol {
                Image(systemName: symbol)
                    .font(.system(size: glyphSize, weight: .semibold))
                    .foregroundColor(T.studio.ink)
            } else {
                Text(vendor.monogram)
                    .font(.system(size: monogramSize,
                                  weight: .heavy,
                                  design: vendor == .ggmlOrg ? .monospaced : .rounded))
                    .foregroundColor(T.studio.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: size.px, height: size.px)
        // Glass-edge highlight — same hairline language as KSection.
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(T.isDark ? 0.10 : 0.20), lineWidth: 0.5)
        )
    }

    // MARK: - Size knobs

    private var cornerRadius: CGFloat { size.px * 0.24 }
    private var glyphSize: CGFloat    { size.px * 0.50 }
    private var monogramSize: CGFloat {
        // IBM/HF and other multi-glyph monograms need a smaller body
        // size to fit, while single letters can fill the tile.
        let multiChar = vendor.monogram.count > 1
        return size.px * (multiChar ? 0.36 : 0.55)
    }
}

// MARK: - Preview (debug only)

#if DEBUG
private struct CapabilityPillPreview: View {
    var body: some View {
        VStack(spacing: 18) {
            KCapabilityPillRow(capabilities: [.recommended, .best, .newRelease,
                                              .vision, .thinking, .gated])
            HStack(spacing: 8) {
                KVendorThumb(vendor: .apple, size: .row)
                KVendorThumb(vendor: .google, size: .row)
                KVendorThumb(vendor: .mistral, size: .row)
                KVendorThumb(vendor: .qwen, size: .row)
                KVendorThumb(vendor: .ibm, size: .row)
                KVendorThumb(vendor: .huggingFace, size: .row)
                KVendorThumb(vendor: .ggmlOrg, size: .row)
                KVendorThumb(vendor: .mlxCommunity, size: .row)
                KVendorThumb(vendor: .liquid, size: .row)
            }
            HStack(spacing: 12) {
                KVendorThumb(vendor: .qwen, size: .card)
                KVendorThumb(vendor: .google, size: .hero)
            }
        }
        .padding()
        .background(KoduTheme.dark.bg)
        .koduTheme(.dark)
    }
}

#Preview {
    CapabilityPillPreview()
}
#endif
