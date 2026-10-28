import SwiftUI

public enum ODConversationDetailAction: Equatable { case model, pin, search, share, delete }

/// A brief conversation control sheet. The existing host owns every action.
public struct ODConversationDetails: View {
    public let title: String
    public let modelName: String
    public let executionLabel: String
    public let workspace: String?
    public let isPinned: Bool
    public let hasConversation: Bool
    public let hasTranscript: Bool
    public let onAction: (ODConversationDetailAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var contentHeight: CGFloat = 380

    public init(title: String, modelName: String, executionLabel: String,
                workspace: String? = nil, isPinned: Bool, hasConversation: Bool,
                hasTranscript: Bool, onAction: @escaping (ODConversationDetailAction) -> Void) {
        self.title = title
        self.modelName = modelName
        self.executionLabel = executionLabel
        self.workspace = workspace
        self.isPinned = isPinned
        self.hasConversation = hasConversation
        self.hasTranscript = hasTranscript
        self.onAction = onAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ODLayout.groupGap) {
                ODConversationSheetIdentity(title: title, workspace: workspace, onClose: { dismiss() })
                ODConversationSheetActions(isPinned: isPinned, hasConversation: hasConversation,
                    hasTranscript: hasTranscript, onAction: onAction)
                ODConversationSheetModel(modelName: modelName, executionLabel: executionLabel) { onAction(.model) }
                if hasConversation {
                    Button(role: .destructive) { onAction(.delete) } label: {
                        Label(ODLocalizedString("Delete conversation"), systemImage: "trash")
                            .font(.subheadline).foregroundStyle(ODPalette.red)
                            .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ODPressButtonStyle())
                    .accessibilityIdentifier("chat.session.delete")
                }
            }
            .padding(.horizontal, ODLayout.groupGap)
            .padding(.top, ODLayout.groupGap)
            .padding(.bottom, ODLayout.elementGap)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                contentHeight = ceil(height) + ODLayout.elementGap
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight), .large])
        .presentationDragIndicator(.visible)
        .background {
            Color.clear
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: ODLayout.composerCorner, style: .continuous))
                .ignoresSafeArea()
        }
        .presentationCornerRadius(ODLayout.composerCorner)
        .presentationBackground(.clear)
    }
}

private struct ODConversationSheetIdentity: View {
    let title: String
    let workspace: String?
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: ODLayout.labelGap) {
            VStack(alignment: .leading, spacing: ODLayout.elementGap) {
                ODAgentLabel()
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(ODPalette.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("chat.session.title")
                if let workspace {
                    Label(workspace, systemImage: "arrow.triangle.branch")
                        .font(.caption).foregroundStyle(ODPalette.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.body.weight(.medium))
                    .foregroundStyle(ODPalette.secondary)
                    .frame(width: ODLayout.minimumHit, height: ODLayout.minimumHit)
                    .contentShape(Circle())
            }
            .buttonStyle(ODPressButtonStyle())
            .accessibilityLabel(Text("Done", bundle: .module))
        }
    }
}

private struct ODConversationSheetActions: View {
    let isPinned: Bool
    let hasConversation: Bool
    let hasTranscript: Bool
    let onAction: (ODConversationDetailAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ODLayout.elementGap),
                                count: typeSize.isAccessibilitySize ? 1 : 3), spacing: ODLayout.elementGap) {
            ODConversationSheetAction(title: isPinned ? "Unpin" : "Pin", symbol: isPinned ? "pin.slash" : "pin",
                                      enabled: hasConversation, id: "pin") { onAction(.pin) }
            ODConversationSheetAction(title: "Search", symbol: "magnifyingglass",
                                      enabled: hasTranscript, id: "search") { onAction(.search) }
            ODConversationSheetAction(title: "Share", symbol: "square.and.arrow.up",
                                      enabled: hasTranscript, id: "share") { onAction(.share) }
        }
    }
}

private struct ODConversationSheetAction: View {
    let title: String
    let symbol: String
    let enabled: Bool
    let id: String
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: ODLayout.labelGap))
                : AnyLayout(VStackLayout(spacing: ODLayout.elementGap))
            layout {
                Image(systemName: symbol).font(.title3.weight(.regular)).accessibilityHidden(true)
                Text(odKey: title).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(enabled ? ODPalette.text : ODPalette.secondary)
            .frame(maxWidth: .infinity, minHeight: ODLayout.minimumHit + ODLayout.labelGap)
            .contentShape(Rectangle())
        }
        .buttonStyle(ODPressButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("chat.session.\(id)")
    }
}

private struct ODConversationSheetModel: View {
    let modelName: String
    let executionLabel: String
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.labelGap) {
            Button(action: onSelect) {
                HStack(spacing: ODLayout.labelGap) {
                    VStack(alignment: .leading, spacing: ODLayout.unit) {
                        Text("Model", bundle: .module).font(.caption).foregroundStyle(ODPalette.secondary)
                        Text(modelName).font(.subheadline.weight(.medium)).foregroundStyle(ODPalette.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                        .foregroundStyle(ODPalette.secondary).accessibilityHidden(true)
                }
                .frame(minHeight: ODLayout.minimumHit).contentShape(Rectangle())
            }
            .buttonStyle(ODPressButtonStyle())
            .accessibilityIdentifier("chat.session.model")
            ODHairline()
            HStack(alignment: .firstTextBaseline, spacing: ODLayout.elementGap) {
                Text("Execution", bundle: .module)
                Spacer(minLength: ODLayout.elementGap)
                Text(odKey: executionLabel)
            }
            .font(.caption).foregroundStyle(ODPalette.secondary)
        }
        .padding(ODLayout.pageInset)
        .background(ODPalette.text.opacity(0.045), in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
    }
}
