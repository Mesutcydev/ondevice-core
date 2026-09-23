import SwiftUI

// MARK: - LegalDocumentView
// Renders any of the long-form legal texts (Privacy, EULA, AI Disclaimer)
// with consistent typography and an optional "I Agree" action button.

struct LegalDocumentView: View {

    let title: String
    let markdown: String
    let externalURL: String?
    /// When non-nil, shown as a primary action button at the bottom.
    let primaryAction: (label: String, run: () -> Void)?
    /// When non-nil, shown as a secondary destructive action.
    let secondaryAction: (label: String, run: () -> Void)?
    /// Consent mode: when non-nil, an "I have read this" confirm button is
    /// shown that ENABLES only after the user scrolls to the end, and tapping
    /// it runs this closure + dismisses. Used by the first-launch legal gate so
    /// "opened the sheet" no longer counts as "read" (the recorded acceptance
    /// reflects genuine review).
    let onReadConfirmed: (() -> Void)?

    init(
        title: String,
        markdown: String,
        externalURL: String? = nil,
        primaryAction: (label: String, run: () -> Void)? = nil,
        secondaryAction: (label: String, run: () -> Void)? = nil,
        onReadConfirmed: (() -> Void)? = nil
    ) {
        self.title = title
        self.markdown = markdown
        self.externalURL = externalURL
        self.primaryAction = primaryAction
        self.secondaryAction = secondaryAction
        self.onReadConfirmed = onReadConfirmed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.koduTheme) private var T
    /// Flips true once the bottom sentinel scrolls into view (or immediately
    /// for documents short enough to fit without scrolling).
    @State private var scrolledToEnd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    // LazyVStack so the bottom sentinel's onAppear fires only
                    // when it actually scrolls into view (a plain VStack would
                    // fire every child's onAppear up front, defeating the gate).
                    LazyVStack(spacing: 0) {
                        MarkdownTextView(markdown: markdown)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 32)
                        Color.clear
                            .frame(height: 1)
                            .onAppear { scrolledToEnd = true }
                    }
                }

                if primaryAction != nil || secondaryAction != nil || onReadConfirmed != nil {
                    Rectangle().fill(T.rule).frame(height: 1)
                    actionBar
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(T.surface)
                }
            }
            .background(StudioPageBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let urlStr = externalURL, let url = URL(string: urlStr) {
                        Link(destination: url) {
                            Image(systemName: "safari").foregroundColor(T.accent)
                        }
                    } else {
                        Button("Done") { dismiss() }
                            .foregroundColor(T.ink)
                    }
                }
                if externalURL != nil {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: 12) {
            if let confirm = onReadConfirmed {
                Button(scrolledToEnd ? "I have read this" : "Scroll to the end to continue") {
                    confirm()
                    dismiss()
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.glassProminent).controlSize(.large)
                .tint(T.ink).foregroundStyle(T.bg)
                .disabled(!scrolledToEnd)
            }
            if let secondary = secondaryAction {
                Button(secondary.label, role: .destructive, action: secondary.run)
                    .buttonStyle(.glass).controlSize(.large)
            }
            if let primary = primaryAction {
                Button(primary.label, action: primary.run)
                    .buttonStyle(.glassProminent).controlSize(.large)
                    .tint(T.ink).foregroundStyle(T.bg)
            }
        }
    }
}
