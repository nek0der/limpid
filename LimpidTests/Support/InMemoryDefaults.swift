// InMemoryDefaults.swift
// Limpid — a `UserDefaults` that never touches disk, for stores that write
// preferences.

import Foundation

/// Keeps every value in memory, so a test can set the app language without
/// writing `appLanguage` or `AppleLanguages` into the test host's real
/// preferences under `~/Library`. Only the accessors the stores use are
/// overridden; each reads and writes the dictionary below.
///
/// `@unchecked Sendable` because `UserDefaults` is declared `Sendable` and
/// the dictionary is mutable: the suites that use it run on the main actor,
/// so no two accesses overlap.
final class InMemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]

    /// `suiteName` is never written through: every accessor below answers
    /// from `values` instead.
    init?(suiteName: String = "dev.limpid.tests.in-memory") {
        super.init(suiteName: suiteName)
    }

    override func object(forKey defaultName: String) -> Any? {
        values[defaultName]
    }

    override func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    override func array(forKey defaultName: String) -> [Any]? {
        values[defaultName] as? [Any]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        values[defaultName] = nil
    }
}
