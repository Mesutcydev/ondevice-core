import SwiftUI

// MARK: - Studio chat pieces
//
// The thread reads as a document: user turns are blocks with a spine, answers
// are full-measure prose with no bubble and no avatar. These are the parts
// that aren't a restyle of something that already existed.

// MARK: - Web permission

/// Approval card for `web_search`. The exact query and the scope of each
/// choice remain visible before any request leaves the device.
struct StudioWebPermissionCard: View {
    /// The words that would actually be sent.
    let query: String
    /// Optional extra sentence from the caller (the tool's own reason).
    var reason: String?
    var onAllowOnce: () -> Void
    var onAlwaysAllow: (() -> Void)?
    var onDeny: () -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(alignment: .leading, spacing: 16) {
            WebPermissionHeader()
            WebPermissionDisclosure(query: query, reason: reason)
            WebPermissionActions(
                onAllowOnce: onAllowOnce,
                onAlwaysAllow: onAlwaysAllow,
                onDeny: onDeny
            )
        }
        .padding(StudioSpacing.l)
        .frame(maxWidth: 520, alignment: .leading)
        .background(S.surfaceRaised, in: RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: StudioRadius.panel, style: .continuous)
                .stroke(S.rule, lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

private struct WebPermissionHeader: View {
    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "globe")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(S.ink)
                .frame(width: 36, height: 36)
                .background(S.fillActive, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Web access requested")
                    .font(S.sans(16, .semibold))
                    .foregroundStyle(S.ink)
                Text("Review what will be sent")
                    .font(S.sans(13))
                    .foregroundStyle(S.ink2)
            }
        }
    }
}

private struct WebPermissionDisclosure: View {
    let query: String
    let reason: String?
    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text("REQUEST")
                    .font(S.mono(10, .medium))
                    .tracking(0.7)
                    .foregroundStyle(S.ink3)
                Text(query)
                    .font(S.sans(15, .medium))
                    .foregroundStyle(S.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(S.fillActive, in: RoundedRectangle(cornerRadius: StudioRadius.tile))

            Text("Only this request is sent from your chat. The rest stays here.")
                .font(S.sans(13))
                .foregroundStyle(S.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if let reason, !reason.isEmpty {
                Text(reason)
                    .font(S.sans(12))
                    .foregroundStyle(S.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct WebPermissionActions: View {
    let onAllowOnce: () -> Void
    let onAlwaysAllow: (() -> Void)?
    let onDeny: () -> Void
    @Environment(\.koduTheme) private var T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let S = T.studio
        VStack(spacing: 5) {
            Button {
                HapticManager.impact(.light)
                onAllowOnce()
            } label: {
                Text("Look it up once")
                    .font(S.sans(15, .semibold))
                    .foregroundStyle(S.paper)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(S.ink, in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)

            let secondaryLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 0))
                : AnyLayout(HStackLayout(spacing: 8))
            secondaryLayout {
                if let onAlwaysAllow {
                    Button {
                        HapticManager.impact(.light)
                        onAlwaysAllow()
                    } label: {
                        Text("Always allow future web requests")
                            .font(S.sans(13, .medium))
                            .foregroundStyle(S.ink2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    HapticManager.impact(.light)
                    onDeny()
                } label: {
                    Text("Never mind")
                        .font(S.sans(13, .medium))
                        .foregroundStyle(S.ink2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Starter list

/// One suggested opening. `label` is what the row reads; `prompt` is what
/// actually lands in the composer — they differ because a good row label
/// ("Explain something") is not a good prompt ("Explain in simple terms: ").
struct StudioStarter: Identifiable {
    let label: String
    let prompt: String
    var id: String { label }

    init(_ label: String, prompt: String) {
        self.label = label
        self.prompt = prompt
    }
}

/// Full-width starter rows with 1px separators. No cards.
struct StudioStarterList: View {
    let starters: [StudioStarter]
    let onPick: (StudioStarter) -> Void

    @Environment(\.koduTheme) private var T

    var body: some View {
        let S = T.studio
        VStack(spacing: 0) {
            StudioHairline(color: S.rule2)
            // Command lines, not suggestion chips. A leading `>` says these
            // are things you send; the chevron said they were places you go,
            // which was never true — picking one fills the composer.
            ForEach(starters) { starter in
                Button {
                    HapticManager.impact(.light)
                    onPick(starter)
                } label: {
                    HStack(spacing: 10) {
                        Text(">")
                            .font(S.mono(13, .medium))
                            .foregroundStyle(S.accent)
                            .accessibilityHidden(true)
                        Text(starter.label)
                            .font(S.sans(15))
                            .foregroundStyle(S.ink)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                StudioHairline(color: S.rule2)
            }
        }
    }
}
