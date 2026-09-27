import SwiftUI
import OnDeviceUI

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
        NavigationStack {
            List {
                Section {
                    Text("Read these four documents before continuing. Each is marked as read after you reach its end and confirm.")
                        .font(.body).foregroundStyle(.secondary)
                }
                Section {
                    documentRow(title: "Privacy policy", subtitle: "How your information is handled", icon: "lock.shield", accepted: $didReadPrivacy) { showPrivacy = true }
                    documentRow(title: "License & safety", subtitle: "Licensing and third-party notices", icon: "doc.text", accepted: $didReadEULA) { showEULA = true }
                    documentRow(title: "AI output disclaimer", subtitle: "Accuracy and limitations", icon: "exclamationmark.triangle", accepted: $didReadDisclaimer) { showDisclaimer = true }
                    documentRow(title: "Device safety notice", subtitle: "Heat, memory, and battery use", icon: "thermometer.medium", accepted: $didReadDeviceSafety) { showDeviceSafety = true }
                } header: { Text("\(readCount) of 4 read") }
                Section {
                    Button {
                        legal.acceptLegal()
                        legal.acceptDisclaimer()
                        legal.acceptDeviceSafety()
                        HapticManager.impact(.medium)
                        onAccepted()
                    } label: {
                        Text("Agree and continue")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).controlSize(.regular)
                    .tint(ODPalette.text).foregroundStyle(ODPalette.background)
                    .disabled(!canContinue)
                    .accessibilityIdentifier("legal.agree")
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("By tapping Agree and continue you confirm that you have read and accepted all four documents above. You can review them any time in Settings → Legal.")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background { ODPageBackground().ignoresSafeArea() }
            .navigationTitle("Before you begin")
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

    private func documentRow(title: String, subtitle: String, icon: String,
                             accepted: Binding<Bool>, openAction: @escaping () -> Void) -> some View {
        Button(action: openAction) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body)
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: accepted.wrappedValue ? "checkmark.circle.fill" : "chevron.right")
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .foregroundStyle(ODPalette.text).padding(.vertical, 4)
        }
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityValue(accepted.wrappedValue ? "Read" : "Not read yet")
        .accessibilityHint("Opens the document for reading")
    }
}
