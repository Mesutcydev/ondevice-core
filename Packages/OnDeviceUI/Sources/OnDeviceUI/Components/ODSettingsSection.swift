import SwiftUI

/// The bordered card used by the host's settings pages. Compose its contents
/// inside one List row so hairlines never become empty system list rows.
public struct ODSettingsSection<Content: View>: View {
    private let title: String
    private let footer: String?
    private let content: () -> Content

    public init(title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 0, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous)
                        .strokeBorder(ODPalette.line, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: ODLayout.settingsCardCorner, style: .continuous))
                .listRowInsets(EdgeInsets(top: 0, leading: ODLayout.settingsPageInset,
                                         bottom: 0, trailing: ODLayout.settingsPageInset))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(EdgeInsets(top: ODLayout.elementGap, leading: 2 * ODLayout.settingsPageInset,
                                             bottom: 0, trailing: 2 * ODLayout.settingsPageInset))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
        } header: {
            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold)).tracking(1.1)
                    .foregroundStyle(ODPalette.secondary).textCase(nil)
                    .padding(.horizontal, ODLayout.settingsPageInset)
            }
        }
        .listSectionSeparator(.hidden)
    }
}
