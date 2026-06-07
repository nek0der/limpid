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

private let log = Logger.limpid("settings.store")

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
    private static let saveDebounce: Duration = PersistenceTiming.interactive

    /// Set transiently around `settings = ...` assignments that
    /// originate from SettingsFileWatcher — without this
    /// guard, the watcher's reload would write the same data back to
    /// disk and the OS would fire another watcher event, creating a
    /// reload ↔ write feedback loop.
    @ObservationIgnored
    private var suppressNextSave: Bool = false

    /// Directory that hosts `settings.json`. Production callers use the
    /// no-arg `init()` which routes through `LimpidPaths`; tests pass an
    /// isolated `WithTempDir` URL via `init(directory:)` so they don't
    /// touch the user's real Application Support folder.
    @ObservationIgnored
    private let directory: URL

    /// JSON file location for this store instance.
    var settingsFileURL: URL {
        directory.appendingPathComponent("settings.json")
    }

    /// JSON file location for the production install. Used by callers
    /// that hint at the file path without holding a store reference
    /// (e.g. `GhosttyConfigBridge.makeConfigString`).
    static var defaultSettingsFileURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("settings.json")
    }

    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL) {
        self.directory = directory
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
        var loaded = Self.loadFromDiskOrDefault(at: directory.appendingPathComponent("settings.json"))
        // The hero screenshot pipeline runs under `LIMPID_DEMO=1`.
        // Force the toolbar opaque there so the captured PNG doesn't
        // depend on whatever wallpaper / other windows happen to sit
        // behind Limpid on the contributor's Mac — the README image
        // stays bit-for-bit reproducible regardless of host setup.
        // Pin the accent to `.blue` for the same reason: `.default`
        // now follows `Color.accentColor` (the OS System Accent), so
        // without this every contributor would render the hero in
        // their own picked accent.
        if DemoFixture.isDemoActive {
            loaded.appearance.transparency = .off
            loaded.appearance.backgroundOpacity = 1.0
            loaded.appearance.accentColor = .blue
        }
        self.settings = loaded
    }

    // MARK: - Persistence

    private static func loadFromDiskOrDefault(at url: URL) -> LimpidSettings {
        guard FileManager.default.fileExists(atPath: url.path) else {
            log.info("settings.json absent at \(url.path, privacy: .public); using defaults")
            return .default
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
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
            // settings.json is the one file we document as user-editable
            // (the prettyPrinted carve-out in saveNow). A stray comma in
            // a hand edit must not destroy the rest of the file on the
            // next mutation — didSet → scheduleSave would otherwise
            // atomic-replace the bad bytes with defaults. Rename the bad
            // file aside now so the subsequent save lands on a fresh
            // path. Mirrors SessionStore.quarantineCorruptedFile.
            quarantineCorruptedFile(at: url, reason: "decode-failed")
            return .default
        }
    }

    /// Rename a corrupted settings.json to `settings.json.bak-<reason>-<ts>`
    /// so the user's original bytes survive even after defaults take
    /// over. Best-effort; failures are logged.
    private static func quarantineCorruptedFile(at url: URL, reason: String) {
        let ts = Int(Date().timeIntervalSince1970)
        let bak = url.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(reason)-\(ts)")
        do {
            try FileManager.default.moveItem(at: url, to: bak)
            log.notice("quarantined settings.json to \(bak.lastPathComponent, privacy: .public)")
        } catch {
            log.error("failed to quarantine settings.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// Schedule a JSON write after `saveDebounce`. Repeated calls
    /// reset the timer so a slider drag emits one final write.
    private func scheduleSave() {
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDebounce)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Synchronous write — used by `scheduleSave` and at app
    /// termination so an in-flight debounce doesn't lose data.
    func saveNow() {
        let url = settingsFileURL
        SecureFileWrite.ensureUserOnlyDirectory(url.deletingLastPathComponent())
        do {
            // `PersistenceCoders.makeEncoder` skips `.prettyPrinted` in
            // Release; `settings.json` is the one file the user is
            // expected to open in an editor, so override that and keep
            // the file pretty in every build.
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

    /// Cancel any in-flight debounce and force a synchronous write.
    /// Called from `applicationWillTerminate` so a settings edit
    /// inside the 250ms debounce window is not lost when the process
    /// tears down. Sibling stores (`NotificationHistoryStore`,
    /// `FrecencyStore`) use the same name for the same lifecycle hook.
    func flushSynchronously() {
        saveDebounceTask?.cancel()
        saveDebounceTask = nil
        saveNow()
    }

    /// Re-read the file from disk and replace the in-memory snapshot.
    /// Used by the file watcher when an external edit lands
    /// — does NOT schedule a save back (would cause a feedback loop).
    func reloadFromDisk() {
        let fresh = Self.loadFromDiskOrDefault(at: settingsFileURL)
        guard fresh != settings else { return }
        suppressNextSave = true
        settings = fresh
        suppressNextSave = false
    }

}
