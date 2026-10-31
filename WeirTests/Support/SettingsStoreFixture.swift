// SettingsStoreFixture.swift
// Weir — a settings store in a scratch folder, on a Mac set to English.

import Foundation
import Testing
@testable import Weir

extension SettingsStore {
    /// A store kept in `directory`, whose language follows a Mac set to US
    /// English with defaults of its own, so neither the person's settings
    /// nor their system language reach the test.
    static func inEnglish(in directory: URL, sourceLocation: SourceLocation = #_sourceLocation) throws -> SettingsStore {
        let defaults = try #require(InMemoryDefaults(), sourceLocation: sourceLocation)
        return SettingsStore(directory: directory, languageSources: AppLanguageSources(
            defaults: defaults,
            systemPreferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en_US") }
        ))
    }
}
