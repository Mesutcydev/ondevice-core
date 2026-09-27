import SwiftUI

/// Semantic colors live in DesignAssets.xcassets, including complete dark variants.
public enum ODPalette {
    public static let background = Color("ODBackground", bundle: .module)
    public static let surface = Color("ODSurface", bundle: .module)
    public static let chrome = Color("ODChrome", bundle: .module)
    public static let input = Color("ODInput", bundle: .module)
    public static let selected = Color("ODSelected", bundle: .module)
    public static let text = Color("ODText", bundle: .module)
    public static let secondary = Color("ODSecondary", bundle: .module)
    public static let line = Color("ODLine", bundle: .module)
    public static let accent = Color("ODAccent", bundle: .module)
    public static let accentText = Color("ODAccentText", bundle: .module)
    public static let accentSoft = Color("ODAccentSoft", bundle: .module)
    public static let send = Color("ODSend", bundle: .module)
    public static let onSend = Color("ODOnSend", bundle: .module)
    public static let graphite = Color("ODGraphite", bundle: .module)
    public static let ivory = Color("ODIvory", bundle: .module)
    public static let red = Color("ODRed", bundle: .module)
}

/// App-owned content metrics. Native navigation, tabs and glass control geometry
/// are measured by SwiftUI and are deliberately not represented by fixed constants.
public enum ODLayout {
    public static let unit: CGFloat = 4
    public static let u = unit
    public static let pageInset = 4 * unit
    public static let smallGap = unit
    public static let largeGap = 8 * unit
    public static let groupGap = 6 * unit
    public static let chatThreadBottomClearance: CGFloat = 6
    public static let elementGap = 2 * unit
    public static let labelGap = 3 * unit
    public static let bubbleInsetH = 4 * unit
    public static let bubbleInsetV = 3 * unit
    public static let bubbleCorner = 5 * unit
    public static let minimumHit = 11 * unit
    public static let panelCorner = 6 * unit
    public static let panelHorizontalInset = 4 * unit
    /// Extra breathing room between the writing text and the panel inset.
    /// The composer scales this with the body text size.
    public static let textAdditionalHorizontalInset = 5 * unit
    /// Inner inset for recent conversation labels in home and sidebar lists.
    public static let conversationRowInset = 2 * unit
    /// Retained for source compatibility with early sidebar integrations.
    public static let sidebarConversationInset = conversationRowInset

    // Two-row composer with a clear writing inset above the text baseline.
    // Both writing and action targets retain a 44-point minimum.
    // The corner radius stays fixed so a taller draft does not become a capsule.
    public static let composerTopInset = 3 * unit
    public static let composerTextMinimumHeight = minimumHit
    public static let composerFooterGap = unit
    public static let composerBottomInset = 4 * unit
    public static let composerAttachmentGap = unit
    public static let composerInputStackGap = unit
    public static let composerMinimumHeight = composerTopInset + composerTextMinimumHeight
        + composerFooterGap + minimumHit + composerBottomInset
    public static let composerCorner: CGFloat = 26
    public static let composerMicPrimaryGap = 2 * unit
    public static let composerAttachmentFaceHeight: CGFloat = 38
    public static let standardIcon = 5 * unit
    public static let rowMinimumHeight = 12 * unit
    public static let sectionMinimumHeight = 7 * unit
    // Settings use one 4-point grid across the host and package screens.
    public static let settingsPageInset = 4 * unit
    public static let settingsCardCorner = 4 * unit
    public static let settingsRowMinimumHeight = 13 * unit
    public static let settingsIconSize = 9 * unit
    public static let settingsPreviewHeight = 24 * unit
    public static let userBubbleWidthFraction: CGFloat = 0.82
    public static let drawerWidthFraction: CGFloat = 0.775
    public static let drawerMaximumWidth = 90 * unit
    public static let readableMaximumWidth = 130 * unit
    public static let attachmentNameMaximumWidth = 40 * unit

    // Existing names remain compatible with the other app surfaces.
    public static let gutter = pageInset
    public static let spacing = elementGap
    public static let corner = 3 * unit
    public static let minimumTarget = minimumHit

    /// availableWidth is measured inside the system horizontal safe area.
    public static func contentWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, availableWidth - 2 * pageInset)
    }

    /// Both natural heights include native control/text layout but exclude panel padding.
    /// Accessibility footer rows contribute their combined measured height and row spacing.
    /// An attachment strip, when present, adds its measured height and the attachment gap.
    /// Image previews are taller than an ordinary file row; pass their measured height.
    public static func composerPanelHeight(textNaturalHeight: CGFloat,
                                    footerNaturalHeight: CGFloat,
                                    attachmentStripHeight: CGFloat? = nil) -> CGFloat {
        let attachmentHeight = attachmentStripHeight.map { max(0, $0) + composerAttachmentGap } ?? 0
        return composerTopInset + attachmentHeight + max(composerTextMinimumHeight, textNaturalHeight)
            + composerFooterGap + max(minimumHit, footerNaturalHeight) + composerBottomInset
    }

    public static func floorPixel(_ value: CGFloat, displayScale: CGFloat) -> CGFloat {
        let scale = max(displayScale, 1)
        return (max(value, 0) * scale).rounded(.down) / scale
    }

    public static func maxUserBubbleWidth(contentWidth: CGFloat, displayScale: CGFloat) -> CGFloat {
        floorPixel(contentWidth * userBubbleWidthFraction, displayScale: displayScale)
    }

    public static func hairline(displayScale: CGFloat) -> CGFloat {
        1 / max(displayScale, 1)
    }

    public static func drawerWidth(availableWidth: CGFloat) -> CGFloat {
        max(0, min(availableWidth * drawerWidthFraction, drawerMaximumWidth))
    }
}

/// A native preference; storage is configurable on ODStore.
public enum ODAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark, oled
    public var id: String { rawValue }
    public var title: String { self == .oled ? "OLED" : rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        case .oled: return "moon.fill"
        }
    }
    public var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark, .oled: return .dark
        }
    }
}

private struct ODAppearanceKey: EnvironmentKey {
    static let defaultValue: ODAppearancePreference = .system
}

extension EnvironmentValues {
    public var odAppearance: ODAppearancePreference {
        get { self[ODAppearanceKey.self] }
        set { self[ODAppearanceKey.self] = newValue }
    }
}

/// The page canvas is distinct from raised surfaces, especially in OLED mode.
public struct ODPageBackground: View {
    @Environment(\.odAppearance) private var appearance
    public init() {}
    public var body: some View {
        (appearance == .oled ? Color.black : ODPalette.background)
    }
}
