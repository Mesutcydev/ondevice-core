import SwiftUI

/// Shared by the app's Appearance screen and the standalone workbench settings.
/// Each choice is visible; the preview uses fixed colors to show what it selects.
public struct ODAppearanceChoices: View {
    @Binding private var selection: ODAppearancePreference
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme

    public init(selection: Binding<ODAppearancePreference>) {
        _selection = selection
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.labelGap) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ODLayout.elementGap), count: typeSize.isAccessibilitySize ? 1 : 3), spacing: ODLayout.labelGap) {
                ForEach([ODAppearancePreference.light, .dark, .oled]) { preference in
                    ODAppearanceOption(preference: preference, selected: selection == preference) {
                        selection = preference
                    }
                }
            }
            Toggle(isOn: Binding(get: { selection == .system }, set: { followsSystem in
                selection = followsSystem ? .system : (colorScheme == .dark ? .dark : .light)
            })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Use device appearance").font(.body)
                    Text("Change with your system settings.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .tint(ODPalette.text)
            .accessibilityIdentifier("appearance.system")
        }
    }
}

private struct ODAppearanceOption: View {
    let preference: ODAppearancePreference
    let selected: Bool
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            Group {
                if typeSize.isAccessibilitySize {
                    HStack(spacing: 16) {
                        preview.frame(width: 84, height: ODLayout.settingsPreviewHeight)
                        selectionLabel.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(spacing: ODLayout.elementGap) {
                        preview.frame(height: ODLayout.settingsPreviewHeight)
                        selectionLabel
                    }
                }
            }
            .frame(minHeight: ODLayout.settingsRowMinimumHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preference.title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("appearance.\(preference.rawValue)")
    }

    private var preview: some View {
        ODAppearancePreview(preference: preference)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(selected ? ODPalette.text : ODPalette.line, lineWidth: selected ? 2 : 1)
            }
    }

    private var selectionLabel: some View {
        HStack(spacing: 6) {
            Text(preference.title).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.subheadline).foregroundStyle(selected ? ODPalette.text : ODPalette.secondary)
        }
        .foregroundStyle(ODPalette.text)
    }

}

private struct ODAppearancePreview: View {
    let preference: ODAppearancePreference
    private var light: Bool { preference == .light }
    private var ink: Color { light ? Color(white: 0.12) : .white }
    private var page: Color { light ? Color(white: 0.98) : Color(white: preference == .oled ? 0 : 0.075) }
    private var surface: Color { light ? Color(white: 0.90) : Color(white: 0.17) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "line.3.horizontal")
                Spacer()
                Circle().fill(ink.opacity(0.5)).frame(width: 4, height: 4)
            }.font(.system(size: 8))
            Text("Aa").font(.system(size: 23, design: .serif))
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(ink.opacity(0.55)).frame(height: 2)
                Capsule().fill(ink.opacity(0.3)).frame(width: 35, height: 2)
            }
            Spacer(minLength: 0)
            HStack {
                Image(systemName: "plus")
                Spacer()
                Image(systemName: "arrow.up.circle.fill")
            }
            .font(.system(size: 9))
            .padding(5)
            .background(surface, in: RoundedRectangle(cornerRadius: 9))
        }
        .foregroundStyle(ink)
        .padding(8)
        .background(page)
        .accessibilityHidden(true)
    }
}
