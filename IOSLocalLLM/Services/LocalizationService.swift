import Foundation
import Combine
import OnDeviceUI

// MARK: - LocalizationService
// The shared OnDeviceUI catalog is the source of truth for app-owned copy.
// Observe this service for live changes; use native localized SwiftUI Text for
// deferred labels, or t()/L()/String.tr for the existing String-based views.
// Unknown keys retain their English source.

typealias AppLanguage = ODAppLanguage

// NB: Deliberately NOT @MainActor on the class. Property initialisers
// like `@ObservedObject private var loc = LocalizationService.shared`
// run in whatever context the surrounding View struct is being
// instantiated in — SwiftUI does some of its diffing work on background
// threads, and isolating `shared` to MainActor crashed on launch with a
// "Crash: data race" once `uiLanguage = "tr"` was persisted (the very
// first view created off-main hit the MainActor barrier). The published
// property mutation does need to be on main; setLanguage dispatches
// it to the main queue. Read paths resolve through immutable bundles.
final class LocalizationService: ObservableObject, @unchecked Sendable {

    static let shared = LocalizationService()

    /// Drives all reactive view re-renders when the user picks a new
    /// language. Backed by AppSettings.uiLanguage so the choice persists
    /// across launches.
    @Published private(set) var language: AppLanguage

    private init() {
        let raw = UserDefaults.standard.string(forKey: "uiLanguage") ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .system

        // The resolved system language is cached for the render path, so it
        // has to be dropped when iOS tells us the user reordered their
        // preferred languages — otherwise a live locale change would keep
        // rendering the old translation until relaunch. Singleton lifetime,
        // so the observer is never removed.
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Self.invalidateSystemLanguageCache()
            self?.objectWillChange.send()
        }
    }

    /// Programmatically change the active language. Persists to
    /// UserDefaults and publishes the change so observing views update
    /// in place — no app restart required. The published mutation is
    /// hopped onto the main actor so SwiftUI's observation pipeline
    /// receives the change on the thread it expects.
    func setLanguage(_ new: AppLanguage) {
        guard new != language else { return }
        UserDefaults.standard.set(new.rawValue, forKey: "uiLanguage")
        if Thread.isMainThread {
            language = new
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.language = new
            }
        }
    }

    /// Cache the resolved system language for the render path. Explicit choices
    /// bypass the cache; locale notifications invalidate it without relaunching.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedSystemLanguage: AppLanguage?

    private static func resolvedSystemLanguage() -> AppLanguage {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = cachedSystemLanguage { return cached }
        let resolved = ODLocalization.resolvedLanguage(.system)
        cachedSystemLanguage = resolved
        return resolved
    }

    /// Drop the resolved system language so the next read re-derives it.
    /// Called when iOS reports the user changed their preferred languages.
    static func invalidateSystemLanguageCache() {
        cacheLock.lock()
        cachedSystemLanguage = nil
        cacheLock.unlock()
    }

    var effectiveLanguage: AppLanguage {
        language != .system ? language : Self.resolvedSystemLanguage()
    }

    func t(_ key: String) -> String {
        ODLocalization.string(key, language: effectiveLanguage)
    }
}

// MARK: - Sugar

/// Free-function shortcut so views can write `L("Settings")` instead of
/// `LocalizationService.shared.t("Settings")`. Note: this is NOT reactive
/// by itself — views that need to update on language change must also
/// observe `LocalizationService.shared`.
func L(_ key: String) -> String {
    LocalizationService.shared.t(key)
}

extension String {
    /// `"Settings".tr` → reads the active translation for this key.
    /// Use inside SwiftUI body of an `@ObservedObject loc = LocalizationService.shared`
    /// view so the read participates in dependency tracking.
    var tr: String { L(self) }
}
