// AppLocaleTests.swift
// Limpid — which locale the app's text uses for each Display Language
// choice, and how `SettingsStore` keeps it current.
//
// Every input is explicit: the OS language list and the user's locale are
// handed in, and preferences go to an in-memory store, so the host Mac's
// settings never decide a result and nothing is written to `~/Library`.

import Foundation
import Testing
@testable import Limpid

@Suite("App locale")
@MainActor
struct AppLocaleTests {
    private let shipped = ["en", "ja"]

    // MARK: - resolvedLocale

    @Test func pinnedLanguages_keepTheUsersRegion() {
        let japanese = AppLanguage.japanese.resolvedLocale(
            preferredLanguages: ["en-US"],
            availableLocalizations: shipped,
            base: Locale(identifier: "en_US")
        )
        #expect(japanese.language.languageCode == .japanese)
        #expect(japanese.region == Locale.Region("US"))

        let english = AppLanguage.english.resolvedLocale(
            preferredLanguages: ["ja-JP"],
            availableLocalizations: shipped,
            base: Locale(identifier: "ja_JP")
        )
        #expect(english.language.languageCode == .english)
        #expect(english.region == Locale.Region("JP"))
    }

    /// The Language & Region choices `Locale.current` carries — calendar,
    /// first weekday, hour cycle, measurement system — survive a switch of
    /// language, so dates and numbers keep the user's format.
    @Test func pinnedLanguages_keepTheUsersFormatChoices() {
        let base = Locale(identifier: "ja_JP@calendar=japanese;fw=mon;hours=h23;measure=metric")
        let english = AppLanguage.english.resolvedLocale(
            preferredLanguages: [],
            availableLocalizations: shipped,
            base: base
        )
        #expect(english.language.languageCode == .english)
        #expect(english.region == Locale.Region("JP"))
        #expect(english.calendar.identifier == .japanese)
        #expect(english.firstDayOfWeek == .monday)
        #expect(english.hourCycle == .zeroToTwentyThree)
        #expect(english.measurementSystem == .metric)
    }

    /// When the language already matches, the user's own locale comes back
    /// untouched, keeping what an identifier cannot carry.
    @Test func matchingLanguage_returnsTheBaseAsIs() {
        let base = Locale(identifier: "ja_JP@calendar=japanese")
        let locale = AppLanguage.japanese.resolvedLocale(
            preferredLanguages: [],
            availableLocalizations: shipped,
            base: base
        )
        #expect(locale == base)
    }

    @Test func system_followsTheOSLanguageList() {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: ["ja-JP", "en-JP"],
            availableLocalizations: ["Base", "en", "ja"],
            base: Locale(identifier: "en_JP")
        )
        #expect(locale.language.languageCode == .japanese)
        #expect(locale.region == Locale.Region("JP"))
    }

    @Test func system_matchesScriptSubtags() {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: ["ja-Jpan-JP"],
            availableLocalizations: shipped,
            base: Locale(identifier: "en_US")
        )
        #expect(locale.language.languageCode == .japanese)
    }

    @Test func system_skipsLanguagesWeDoNotShip() {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: ["zh-Hans-CN", "fr-FR", "ja-JP"],
            availableLocalizations: shipped,
            base: Locale(identifier: "zh_CN")
        )
        #expect(locale.language.languageCode == .japanese)
        #expect(locale.region == Locale.Region("CN"))
    }

    @Test(arguments: [
        (["zh-Hans-CN"], ["ja", "en"]),
        (["fr-FR"], ["Base", "ja", "en"]),
        ([], ["ja", "en"]),
        (["ja-JP"], ["Base"]),
        (["ja-JP"], [])
    ])
    func system_fallsBackToTheDevelopmentLanguage(preferred: [String], available: [String]) {
        let locale = AppLanguage.system.resolvedLocale(
            preferredLanguages: preferred,
            availableLocalizations: available,
            base: Locale(identifier: "fr_FR")
        )
        #expect(locale.language.languageCode == .english)
        #expect(locale.region == Locale.Region("FR"))
    }

    @Test func appleLanguagesValue_matchesThePinnedLocalization() {
        #expect(AppLanguage.system.appleLanguagesValue == nil)
        #expect(AppLanguage.english.appleLanguagesValue == ["en"])
        #expect(AppLanguage.japanese.appleLanguagesValue == ["ja"])
    }

    // MARK: - SettingsStore

    private func sources(
        _ defaults: UserDefaults,
        languages: @escaping () -> [String],
        base: Locale = Locale(identifier: "en_JP")
    ) -> AppLanguageSources {
        AppLanguageSources(defaults: defaults, systemPreferredLanguages: languages, currentLocale: { base })
    }

    @Test func store_followsTheSystemListByDefault() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { ["ja-JP"] })
            #expect(store.appLanguage == .system)
            #expect(store.appLocale.language.languageCode == .japanese)
            #expect(store.appLocale.region == Locale.Region("JP"))
        }
    }

    /// The switch back to System Default is the case that needed a relaunch:
    /// the OS list is read again rather than the language picked before.
    @Test func store_switchesLanguageWithoutARelaunch() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { ["ja-JP"] })

            store.appLanguage = .english
            #expect(store.appLocale.language.languageCode == .english)
            #expect(store.appLocale.region == Locale.Region("JP"))
            #expect(defaults.string(forKey: "appLanguage") == "english")
            #expect(defaults.object(forKey: "AppleLanguages") as? [String] == ["en"])

            store.appLanguage = .system
            #expect(store.appLocale.language.languageCode == .japanese)
            #expect(defaults.object(forKey: "AppleLanguages") == nil)
        }
    }

    @Test func store_readsTheSavedChoice() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            defaults.set("japanese", forKey: "appLanguage")
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { ["en-US"] })
            #expect(store.appLanguage == .japanese)
            #expect(store.appLocale.language.languageCode == .japanese)
        }
    }

    /// A change to the OS language list or region while Limpid runs reaches
    /// System Default without a relaunch.
    @Test func store_followsALocaleChangeWhileRunning() throws {
        try withTempDir { directory in
            let defaults = try #require(InMemoryDefaults())
            var languages = ["en-US"]
            let store = SettingsStore(directory: directory, languageSources: sources(defaults) { languages })
            #expect(store.appLocale.language.languageCode == .english)

            languages = ["ja-JP"]
            NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            #expect(store.appLocale.language.languageCode == .japanese)
        }
    }
}
