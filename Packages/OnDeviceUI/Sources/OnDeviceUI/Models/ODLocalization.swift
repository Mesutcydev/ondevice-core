import Foundation
import SwiftUI

public enum ODAppLanguage: String, CaseIterable, Identifiable, Sendable {
    /// Follow the device's preferred language. If the system language
    /// matches a supported translation we use it; otherwise fall back to
    /// English.
    case system
    case english  = "en"
    case german   = "de"
    case french   = "fr"
    case spanish  = "es"
    case portuguese = "pt"
    case italian  = "it"
    case greek    = "el"
    case romanian = "ro"
    case russian  = "ru"
    case turkish  = "tr"
    case arabic   = "ar"
    case hindi    = "hi"
    case chinese  = "zh-Hans"
    case japanese = "ja"
    case korean   = "ko"

    public var id: String { rawValue }

    /// True for scripts written right-to-left.
    ///
    /// This matters because the app has its OWN language picker, independent
    /// of the system language. SwiftUI derives `layoutDirection` from the
    /// system locale, so a user whose phone is in English but who selects
    /// Arabic here would otherwise read Arabic in a left-to-right layout.
    /// Resolve `.system` before using this property.
    public var isRightToLeft: Bool {
        switch self {
        case .arabic: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .system:     return "System default"
        case .english:    return "English"
        case .german:     return "Deutsch"
        case .french:     return "Français"
        case .spanish:    return "Español"
        case .portuguese: return "Português"
        case .italian:    return "Italiano"
        case .greek:      return "Ελληνικά"
        case .romanian:   return "Română"
        case .russian:    return "Русский"
        case .turkish:    return "Türkçe"
        case .arabic:     return "العربية"
        case .hindi:      return "हिन्दी"
        case .chinese:    return "简体中文"
        case .japanese:   return "日本語"
        case .korean:     return "한국어"
        }
    }

    /// Native-name display used in the picker so each language reads
    /// recognisably regardless of the currently active translation.
    public var nativeName: String {
        switch self {
        case .system:     return "Auto"
        case .english:    return "English"
        case .german:     return "Deutsch"
        case .french:     return "Français"
        case .spanish:    return "Español"
        case .portuguese: return "Português"
        case .italian:    return "Italiano"
        case .greek:      return "Ελληνικά"
        case .romanian:   return "Română"
        case .russian:    return "Русский"
        case .turkish:    return "Türkçe"
        case .arabic:     return "العربية"
        case .hindi:      return "हिन्दी"
        case .chinese:    return "简体中文"
        case .japanese:   return "日本語"
        case .korean:     return "한국어"
        }
    }
}

/// One catalog shared by the package, app, and extensions. Explicit language
/// lookup keeps the app's language picker live without changing AppleLanguages.
public enum ODLocalization {
    public static let supportedLanguages = ODAppLanguage.allCases.filter { $0 != .system }

    public static func resolvedLanguage(_ selection: ODAppLanguage,
                                        preferredLanguages: [String]? = nil) -> ODAppLanguage {
        guard selection == .system else { return selection }
        for identifier in preferredLanguages ?? Locale.preferredLanguages {
            let code = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if let match = supportedLanguages.first(where: {
                code == $0.rawValue.lowercased()
                    || code.split(separator: "-").first == $0.rawValue.lowercased().split(separator: "-").first
            }) { return match }
        }
        return .english
    }

    public static func locale(for selection: ODAppLanguage) -> Locale {
        Locale(identifier: resolvedLanguage(selection).rawValue)
    }

    /// Unknown keys retain their English source. Call only for app-owned copy;
    /// conversation text, model names, file names, and protocol values stay verbatim.
    public static func string(_ key: String, language: ODAppLanguage) -> String {
        let language = resolvedLanguage(language)
        return bundles[language]?.localizedString(forKey: key, value: key, table: "Localizable") ?? key
    }

    private static let bundles: [ODAppLanguage: Bundle] = Dictionary(uniqueKeysWithValues:
        supportedLanguages.compactMap { language in
            guard let path = Bundle.module.path(forResource: language.rawValue, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { return nil }
            return (language, bundle)
        })
}

public extension Text {
    /// Deferred lookup for app-owned labels passed through String properties.
    /// Text still resolves against the SwiftUI locale when the language changes.
    init(odKey key: String) {
        self.init(LocalizedStringKey(key), bundle: .module)
    }
}

/// Shared by production settings and the simulator review host.
public struct ODLanguagePicker: View {
    @Binding private var selection: ODAppLanguage
    public init(selection: Binding<ODAppLanguage>) { _selection = selection }

    public var body: some View {
        Picker(selection: $selection) {
            ForEach(ODAppLanguage.allCases) { language in
                if language == .system {
                    Text("System default", bundle: .module).tag(language)
                } else {
                    Text(verbatim: language.nativeName).tag(language)
                }
            }
        } label: {
            Text("Language", bundle: .module)
        }
        .accessibilityIdentifier("settings.language")
    }
}

/// A bundle-qualified resource for native controls with a text title.
func ODLocalizedString(_ key: String.LocalizationValue) -> LocalizedStringResource {
    LocalizedStringResource(key, bundle: .atURL(Bundle.module.bundleURL))
}

func ODLocalizedString(key: String) -> LocalizedStringResource {
    ODLocalizedString(String.LocalizationValue(stringLiteral: key))
}

public extension View {
    /// A resolved title makes UIKit's navigation preference update on a live
    /// locale change. The content keeps its identity, drafts, and scroll state.
    func odNavigationTitle(_ key: String) -> some View {
        modifier(ODLocalizedNavigationTitle(key: key))
    }
}

private struct ODLocalizedNavigationTitle: ViewModifier {
    let key: String
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let language = ODLocalization.resolvedLanguage(.system, preferredLanguages: [locale.identifier])
        content.navigationTitle(ODLocalization.string(key, language: language))
    }
}
