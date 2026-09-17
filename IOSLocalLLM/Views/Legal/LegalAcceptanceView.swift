import SwiftUI

// MARK: - LegalAcceptanceView
// Full-screen gate shown on first launch and whenever the legal version is
// bumped. The user must accept Privacy + EULA + AI Disclaimer + Device Safety
// before the main app UI is reachable.
//
// Studio language: flat page, hairline-ruled document rows, one filled ink
// primary, plain language. Each document only counts as read after the user
// scrolls to its end and confirms — opening the sheet is not enough.

struct LegalAcceptanceView: View {

    @StateObject private var legal = LegalAcceptanceManager.shared
    @State private var didReadPrivacy = false
    @State private var didReadEULA    = false
    @State private var didReadDisclaimer = false
    @State private var didReadDeviceSafety = false

    @State private var showPrivacy = false
    @State private var showEULA    = false
    @State private var showDisclaimer = false
    @State private var showDeviceSafety = false
    @Environment(\.koduTheme) private var T

    let onAccepted: () -> Void

    private var readCount: Int {
        [didReadPrivacy, didReadEULA, didReadDisclaimer, didReadDeviceSafety]
            .filter { $0 }.count
    }
    private var canContinue: Bool { readCount == 4 }

    var body: some View {
        let S = T.studio
        ZStack {
            StudioPageBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 26)

                    HStack(alignment: .firstTextBaseline) {
                        StudioMonoLabel(text: "read & accept", size: 11, tracking: 0.9)
                        Spacer()
                        StudioMonoLabel(text: "\(readCount) of 4 read",
                                        size: 11, tracking: 0.9,
                                        color: canContinue ? S.accent : S.ink3)
                    }
                    .padding(.bottom, StudioSpacing.s)

                    VStack(spacing: 0) {
                        StudioHairline(color: S.rule2)

                        documentRow(
                            title: "Privacy policy",
                            subtitle: "What the app can and cannot see",
                            icon: "lock.shield",
                            accepted: $didReadPrivacy
                        ) { showPrivacy = true }

                        documentRow(
                            title: "License & safety",
                            subtitle: "MIT license and third-party notices",
                            icon: "doc.text",
                            accepted: $didReadEULA
                        ) { showEULA = true }

                        documentRow(
                            title: "AI output disclaimer",
                            subtitle: "AI can be wrong — verify what matters",
                            icon: "exclamationmark.triangle",
                            accepted: $didReadDisclaimer
                        ) { showDisclaimer = true }

                        documentRow(
                            title: "Device safety notice",
                            subtitle: "On-device AI runs the device warm",
                            icon: "thermometer.medium",
                            accepted: $didReadDeviceSafety
                        ) { showDeviceSafety = true }
                    }

                    StudioPrimaryButton(title: "Agree and continue") {
                        legal.acceptLegal()
                        legal.acceptDisclaimer()
                        legal.acceptDeviceSafety()
                        HapticManager.impact(.medium)
                        onAccepted()
                    }
                    .opacity(canContinue ? 1 : 0.4)
                    .disabled(!canContinue)
                    .padding(.top, 26)

                    Text("By tapping Agree and continue you confirm that you have read and accepted all four documents above. You can review them any time in Settings → Legal.")
                        .font(S.sans(12))
                        .lineSpacing(12 * 0.4)
                        .foregroundStyle(S.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                }
                .padding(.horizontal, StudioSpacing.xl)
                .padding(.vertical, 30)
            }
        }
        // Each doc counts as "read" ONLY after the user scrolls to the end and
        // taps "I have read this" (onReadConfirmed) — not merely on dismiss.
        .sheet(isPresented: $showPrivacy) {
            LegalDocumentView(
                title: "Privacy policy",
                markdown: LegalDocuments.privacyPolicy,
                externalURL: LegalDocuments.privacyPolicyURL,
                onReadConfirmed: { didReadPrivacy = true }
            )
        }
        .sheet(isPresented: $showEULA) {
            LegalDocumentView(
                title: "License & safety",
                markdown: LegalDocuments.eula,
                externalURL: LegalDocuments.eulaURL,
                onReadConfirmed: { didReadEULA = true }
            )
        }
        .sheet(isPresented: $showDisclaimer) {
            LegalDocumentView(
                title: "AI output disclaimer",
                markdown: LegalDocuments.aiDisclaimer,
                onReadConfirmed: { didReadDisclaimer = true }
            )
        }
        .sheet(isPresented: $showDeviceSafety) {
            LegalDocumentView(
                title: "Device safety notice",
                markdown: LegalDocuments.deviceSafetyNotice,
                onReadConfirmed: { didReadDeviceSafety = true }
            )
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        let S = T.studio
        return VStack(alignment: .leading, spacing: 0) {
            StudioMonoLabel(text: "first launch", size: 11, tracking: 0.9)
                .padding(.bottom, 10)

            Text("Before\nyou start.")
                .font(S.sans(32, .semibold))
                .tracking(-0.8)
                .lineSpacing(32 * 0.14)
                .foregroundStyle(S.ink)

            Text("Four short documents: privacy, licensing, AI accuracy, and device safety. Read each one below — the agreement unlocks once all four are checked.")
                .font(S.sans(15))
                .lineSpacing(15.5 * 0.5)
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func documentRow(
        title: String,
        subtitle: String,
        icon: String,
        accepted: Binding<Bool>,
        openAction: @escaping () -> Void
    ) -> some View {
        let S = T.studio
        Button {
            HapticManager.impact(.light)
            openAction()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(S.ink)
                    .frame(width: 36, height: 36)
                    .background(S.fillActive,
                                in: RoundedRectangle(cornerRadius: StudioRadius.glyph,
                                                     style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(S.sans(16)).foregroundStyle(S.ink)
                    Text(subtitle).font(S.sans(13)).foregroundStyle(S.ink3)
                }

                Spacer(minLength: StudioSpacing.s)

                if accepted.wrappedValue {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(S.accent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13))
                        .foregroundStyle(S.chevron)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { StudioHairline(color: S.rule2) }
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityValue(accepted.wrappedValue ? "Read" : "Not read yet")
        .accessibilityHint("Opens the document for reading")
    }
}
