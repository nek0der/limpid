// AppLanguage.swift
// Limpid — user-facing app language choice and the locale it stands for.
//
// The Settings picker drives two things:
//   1. `SettingsStore.appLocale`, which every window hands SwiftUI as
//      `\.locale` and which text drawn outside SwiftUI (AppKit menus,
//      alerts, review rows, notifications, the agent prompt) resolves
//      through (`LocalizedStringResource.resolved(in:)`). Both flip the
//      moment the language is picked.
//   2. UserDefaults `AppleLanguages`, which the AppKit menu bar reads
//      only at process start, so the menu bar follows on next launch.

import CoreFoundation
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    /// Follow the OS-wide preferred language list.
    case system
    case english
    case japanese

    var id: String {
        rawValue
    }

    /// The picker label. The two languages are endonyms, the same text in
    /// every language, so only "System Default" changes with the locale.
    var localizedTitle: LocalizedStringResource {
        switch self {
        case .system: "System Default"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    /// The localization this choice pins, or `nil` for `.system`, which
    /// follows the OS language list instead.
    var pinnedLocalization: String? {
        switch self {
        case .system: nil
        case .english: "en"
        case .japanese: "ja"
        }
    }

    /// What to write into `UserDefaults["AppleLanguages"]`. AppKit
    /// reads this at process start; setting `nil` (handled by the
    /// caller with `removeObject(forKey:)`) reverts to OS default.
    var appleLanguagesValue: [String]? {
        pinnedLocalization.map { [$0] }
    }

    /// The localization the app falls back to when none of the user's
    /// languages is one we ship.
    static let developmentLocalization = "en"

    /// The locale in-app text uses for this choice.
    ///
    /// - Parameters:
    ///   - preferredLanguages: The user's OS language list, most preferred
    ///     first. Only `.system` reads it. It must be the global list, not
    ///     `Locale.preferredLanguages` or `Locale.current`: once a language
    ///     is picked we write `AppleLanguages` into our own domain, and
    ///     both of those read that value back (and `Locale.current` is
    ///     fixed at launch besides), so "System Default" would keep the
    ///     language picked before it until relaunch.
    ///   - availableLocalizations: The localizations the bundle ships.
    ///   - base: The user's own locale, `Locale.current` in the app. Only
    ///     its language is replaced: the region and the Language & Region
    ///     choices it carries (calendar, first weekday, hour cycle,
    ///     measurement and numbering system) stay, so dates and numbers keep
    ///     the user's format. When the language already matches, `base` is
    ///     returned as is, which also keeps choices a locale identifier
    ///     cannot carry (custom number separators).
    func resolvedLocale(
        preferredLanguages: [String],
        availableLocalizations: [String] = Bundle.main.localizations,
        base: Locale
    ) -> Locale {
        let localization = pinnedLocalization
            ?? Self.bestLocalization(
                preferredLanguages: preferredLanguages,
                availableLocalizations: availableLocalizations
            )
        let languageCode = Locale.Language(identifier: localization).languageCode
        if base.language.languageCode == languageCode {
            return base
        }
        var components = Locale.Components(locale: base)
        // Only the language code: a script carried over from the base
        // (`Latn` from `en`) would not match the new language, and the
        // region is the user's, so it stays.
        components.languageComponents = Locale.Language.Components(
            languageCode: languageCode,
            script: nil,
            region: base.language.region
        )
        return Locale(components: components)
    }

    /// The shipped localization that best matches `preferredLanguages`,
    /// with Foundation's own matching (so `ja-JP` picks `ja`, and a list
    /// with no shipped language falls back to the development language).
    private static func bestLocalization(
        preferredLanguages: [String],
        availableLocalizations: [String]
    ) -> String {
        let shipped = availableLocalizations.filter { $0 != "Base" }
        guard !shipped.isEmpty else { return developmentLocalization }
        let matches = Bundle.preferredLocalizations(from: shipped, forPreferences: preferredLanguages)
        // With nothing in the list shipped, `preferredLocalizations` still
        // answers with one of the shipped entries by rules of its own, so
        // the fallback is named here: the development language.
        guard let best = matches.first,
              preferredLanguages.contains(where: { Self.language(of: $0) == Self.language(of: best) })
        else {
            return shipped.contains(developmentLocalization) ? developmentLocalization : shipped[0]
        }
        return best
    }

    private static func language(of identifier: String) -> String? {
        Locale.Language(identifier: identifier).languageCode?.identifier
    }

    /// The OS-wide language list, read from the global preferences domain
    /// so the `AppleLanguages` value we write into our own domain does not
    /// shadow it.
    static func systemPreferredLanguages() -> [String] {
        let value = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
        // A missing or malformed value means the OS has no explicit list,
        // which the matching treats as "use the development language".
        return (value as? [String]) ?? []
    }
}
