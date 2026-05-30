// SettingsStore.swift
// Limpid — single source of truth for user preferences. Splits into
// two backings on purpose:
//
//   - `@AppStorage("appLanguage")` for the language picker. AppKit's
//     menu bar reads UserDefaults at launch, so we keep the language
//     in plist territory to influence the bar without a JSON loader.
//
//   - `<LimpidPaths app support>/settings.json` for everything that
//     drives the terminal (font, theme, opacity, bell, scrollback…).
//     The path is per-build via `LimpidPaths` so Release / Debug /
//     test hosts each keep their own file. One Codable struct
//     (`LimpidSettings`)
//     round-trips the whole file. The UI binds to nested fields via
//     SwiftUI's path bindings; mutations debounce-write back to the
//     file so external editors (and the future file watcher) stay in
//     sync.
//
// Secrets (API keys) must NOT live here — use Keychain.

import Foundation
import Observation
import OSLog
import SwiftUI

private let log = Logger(subsystem: "dev.limpid", category: "settings.store")

@Observable
@MainActor
final class SettingsStore {

    // MARK: - Language (UserDefaults / AppKit-visible)

    /// User-facing app language. `.system` reads OS Region prefs.
    /// Changes apply to the SwiftUI tree immediately (via locale env);
    /// AppKit menu bar follows on next launch.
    ///
    /// We avoid `@AppStorage` here on purpose: `@AppStorage` is a
    /// `DynamicProperty` designed for `View` types, and combining it
    /// with `@ObservationIgnored` inside an `@Observable` class
    /// silently breaks change tracking — SwiftUI never re-evaluates
    /// the dependent views on set. Storing a plain `String` lets the
    /// `@Observable` macro instrument the read/write, and we mirror
    /// to UserDefaults manually so AppKit's `AppleLanguages` lookup
    /// at next launch still sees the value.
    private static let appLanguageDefaultsKey = "appLanguage"

    var appLanguage: AppLanguage {
        didSet {
            guard appLanguage != oldValue else { return }
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Self.appLanguageDefaultsKey)
            applyAppleLanguages(for: appLanguage)
        }
    }

    private func applyAppleLanguages(for lang: AppLanguage) {
        let key = "AppleLanguages"
        if let value = lang.appleLanguagesValue {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - LimpidSettings (settings.json)

    /// In-memory mirror of `settings.json`. SwiftUI views observe
    /// this through @Observable; assigning a new value also schedules
    /// a debounced save so external file watchers see the change.
    var settings: LimpidSettings {
        didSet {
            guard settings != oldValue else { return }
            guard !suppressNextSave else { return }
            scheduleSave()
        }
    }

    private var saveDebounceTask: Task<Void, Never>?
    /// Delay between the last mutation and the file write. Coalesces
    /// the burst of writes a slider produces while it's being dragged.
    private static let saveDebounce: Duration = .milliseconds(250)

    /// Set transiently around `settings = ...` assignments that
    /// originate from SettingsFileWatcher — without this
    /// guard, the watcher's reload would write the same data back to
    /// disk and the OS would fire another watcher event, creating a
    /// reload ↔ write feedback loop.
    @ObservationIgnored
    private var suppressNextSave: Bool = false

    init() {
        let raw = UserDefaults.standard.string(forKey: Self.appLanguageDefaultsKey)
            ?? AppLanguage.system.rawValue
        let stored = AppLanguage(rawValue: raw) ?? .system
        // Demo mode pins the SwiftUI tree to English so the README hero
        // screenshot reads the same regardless of the contributor's OS
        // locale. UserDefaults stays untouched so the user's real
        // preference survives a `LIMPID_DEMO=1` run. AppKit menu bar
        // still follows `AppleLanguages` (untouched here) — capture
        // pipelines crop to the SwiftUI window content.
        self.appLanguage = DemoFixture.isDemoActive ? .english : stored
        var loaded = Self.loadFromDiskOrDefault()
        // The hero screenshot pipeline runs under `LIMPID_DEMO=1`.
        // Force the chrome opaque there so the captured PNG doesn't
        // depend on whatever wallpaper / other windows happen to sit
        // behind Limpid on the contributor's Mac — the README image
        // stays bit-for-bit reproducible regardless of host setup.
        if DemoFixture.isDemoActive {
            loaded.appearance.transparencyEnabled = false
            loaded.appearance.backgroundOpacity = 1.0
        }
        self.settings = loaded
    }

    // MARK: - Persistence

    /// JSON file location. Routes through `LimpidPaths` so Debug
    /// builds (`Limpid Dev/settings.json`) and Release builds
    /// (`Limpid/settings.json`) stay separated on the same Mac.
    static var settingsFileURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("settings.json")
    }

    private static func loadFromDiskOrDefault() -> LimpidSettings {
        let url = settingsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.info("settings.json absent at \(url.path, privacy: .public); using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(LimpidSettings.self, from: data)
            if decoded.schemaVersion != LimpidSettings.currentSchemaVersion {
                log.notice("""
                settings.json schema v\(decoded.schemaVersion, privacy: .public) \
                != expected v\(LimpidSettings.currentSchemaVersion, privacy: .public); \
                keeping decoded values
                """)
            }
            return decoded
        } catch {
            log.error("settings.json decode failed: \(String(describing: error), privacy: .public). Using defaults.")
            return .default
        }
    }

    /// Schedule a JSON write after `saveDebounce`. Repeated calls
    /// reset the timer so a slider drag emits one final write.
    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            await self?.saveNow()
        }
    }

    /// Synchronous write — used by `scheduleSave` and at app
    /// termination so an in-flight debounce doesn't lose data.
    func saveNow() {
        let url = Self.settingsFileURL
        SecureFileWrite.ensureUserOnlyDirectory(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            // Same 0600 path as `state.json` / `notifications.json` —
            // `settings.json` may not carry secrets today but it's
            // still the user's machine-local prefs file and shouldn't
            // ship out with the default 0644.
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("settings.json save failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Re-read the file from disk and replace the in-memory snapshot.
    /// Used by the file watcher when an external edit lands
    /// — does NOT schedule a save back (would cause a feedback loop).
    func reloadFromDisk() {
        let fresh = Self.loadFromDiskOrDefault()
        guard fresh != settings else { return }
        // Bypass didSet's scheduleSave by using a flag.
        suppressNextSave = true
        settings = fresh
        suppressNextSave = false
    }

}
