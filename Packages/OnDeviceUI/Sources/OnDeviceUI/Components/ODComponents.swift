import SwiftUI

/// A quiet grouped surface. Use for controls or sheets, not around every section.
struct ODSurface<Content: View>: View {
    private let padding: CGFloat
    private let content: Content

    init(padding: CGFloat = ODLayout.bubbleInsetH, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(ODPalette.surface, in: RoundedRectangle(cornerRadius: ODLayout.corner, style: .continuous))
    }
}

struct ODHairline: View {
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle()
            .fill(ODPalette.line)
            .frame(height: ODLayout.hairline(displayScale: displayScale))
            .accessibilityHidden(true)
    }
}

/// OnDevice's sole display-serif element. No external font dependency is required.
struct ODWordmark: View {
    private let style: Font.TextStyle
    init(style: Font.TextStyle = .largeTitle) { self.style = style }
    var body: some View {
        Text("OnDevice")
            .font(.system(style, design: .serif).weight(.bold))
            .foregroundStyle(ODPalette.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("OnDevice")
    }
}


struct ODSectionHeader: View {
    private let title: String
    private let accessory: String?
    private let action: (() -> Void)?

    init(_ title: String, accessory: String? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.accessory = accessory
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ODLayout.labelGap) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(ODPalette.secondary)
                .accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let accessory {
                if let action {
                    Button(action: action) {
                        HStack(spacing: ODLayout.unit) {
                            Text(accessory).font(.subheadline)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(ODPalette.secondary)
                        .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ODPressButtonStyle())
                } else {
                    Text(accessory)
                        .font(.subheadline)
                        .foregroundStyle(ODPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(minHeight: ODLayout.sectionMinimumHeight)
    }
}

struct ODPrimaryButton: View {
    private let title: String
    private let symbol: String?
    private let action: () -> Void

    init(_ title: String, symbol: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: ODLayout.elementGap) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.body.weight(.medium))
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: ODLayout.groupGap)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(.blue)
    }
}

/// A native iOS 26 glass control for content-level actions.
/// Inside a navigation toolbar, use a plain Button so the toolbar owns its glass.
struct ODIconButton: View {
    private let symbol: String
    private let label: String
    private let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = ODLayout.standardIcon

    init(_ symbol: String, label: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(ODPalette.text)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
        .accessibilityLabel(label)
    }
}

/// Borderless search; a focus underline provides a clear active state.
struct ODSearchField: View {
    private let placeholder: String
    @Binding private var text: String
    @FocusState private var focused: Bool
    @Environment(\.displayScale) private var displayScale

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        self._text = text
    }

    var body: some View {
        HStack(spacing: ODLayout.elementGap) {
            Image(systemName: "magnifyingglass")
                .font(.body)
                .foregroundStyle(ODPalette.secondary)
                .accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .font(.body)
                .foregroundStyle(ODPalette.text)
                .tint(ODPalette.accent)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel(placeholder)
                .focused($focused)
                .frame(minHeight: ODLayout.minimumHit)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(ODPalette.secondary)
                        .frame(minWidth: ODLayout.minimumHit, minHeight: ODLayout.minimumHit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ODPressButtonStyle())
                .accessibilityLabel("Clear search")
            }
        }
        .frame(minHeight: ODLayout.rowMinimumHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(focused ? ODPalette.accent : ODPalette.line)
                .frame(height: ODLayout.hairline(displayScale: displayScale) * (focused ? 2 : 1))
                .accessibilityHidden(true)
        }
    }
}

struct ODStatCell: View {
    let title: String
    let value: String
    let detail: String?
    let symbol: String

    init(title: String, value: String, detail: String? = nil, symbol: String) {
        self.title = title
        self.value = value
        self.detail = detail
        self.symbol = symbol
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ODLayout.elementGap) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(ODPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(ODPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(ODPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ODPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? (configuration.isPressed ? 0.60 : 1) : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}


/// The reference's two-line menu mark, drawn natively so it is not SDK-symbol dependent.
public struct ODAppMenuButton: View {
    private let action: () -> Void
    public init(action: @escaping () -> Void) { self.action = action }
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                Capsule().frame(width: 20, height: 2)
                Capsule().frame(width: 13, height: 2)
            }
            .frame(width: 20, height: 20)
            .foregroundStyle(ODPalette.text)
        }
        .buttonBorderShape(.circle)
        .accessibilityLabel("Open app menu")
        .accessibilityIdentifier("navigation.menu")
    }
}
