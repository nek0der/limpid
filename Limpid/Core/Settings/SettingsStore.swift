// SettingsStore.swift
// Limpid — single source of truth for user preferences. Splits into
// two backings on purpose:
//
//   - UserDefaults (`appLanguage`, mirrored into `AppleLanguages`) for
//     the language picker. AppKit's menu bar reads UserDefaults at
//     launch, so we keep the language in plist territory to influence
//     the bar without a JSON loader.
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

private let log = Logger.limpid("settings.store")

@Observable
@MainActor
final class SettingsStore {

    /// Current libghostty configuration diagnostics. These describe the
    /// loaded config rather than a user preference, so they remain in memory
    /// and are refreshed after startup and every live config reload.
    var ghosttyConfigDiagnostics: [String] = []

    // MARK: - Language (UserDefaults / AppKit-visible)

    /// User-facing app language. `.system` follows the OS-wide preferred
    /// language list. Changes apply to in-app text immediately (through `appLocale`);
    /// the AppKit menu bar follows on next launch.
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
            languageSources.defaults.set(appLanguage.rawValue, forKey: Self.appLanguageDefaultsKey)
            applyAppleLanguages(for: appLanguage)
            refreshAppLocale()
        }
    }

    /// The locale every piece of in-app text uses: SwiftUI receives it as
    /// `\.locale` at each window root, and text built outside SwiftUI
    /// (AppKit menus and alerts, notifications, the agent prompt) resolves
    /// with it. Its language is never `Locale.current`'s, which is the one
    /// the process launched with; the rest of the user's locale (region,
    /// calendar, number format) is kept. Stored rather than computed so the
    /// preferences read happens once per change, not once per row.
    private(set) var appLocale: Locale

    /// Where the language picker reads and writes, and what `.system`
    /// follows. Injected so tests run without the host Mac's preferences
    /// and without writing to them.
    @ObservationIgnored
    private let languageSources: AppLanguageSources

    /// The `currentLocaleDidChangeNotification` registration. Kept so
    /// `deinit` can hand it back. `nonisolated(unsafe)` because the
    /// nonisolated `deinit` reads it: it is written once in `init` on the
    /// main actor and read only in `deinit`, when no other reference to the
    /// store remains, so the two accesses cannot overlap.
    @ObservationIgnored
    private nonisolated(unsafe) var localeObserver: (any NSObjectProtocol)?

    /// Recomputes `appLocale` from the picker and the sources. Also runs
    /// when the OS language list or region changes while Limpid runs, so
    /// System Default and the kept region stay current without a relaunch.
    private func refreshAppLocale() {
        let locale = Self.locale(for: appLanguage, sources: languageSources)
        if locale != appLocale {
            appLocale = locale
        }
    }

    /// The locale for `language`. Demo mode starts from plain English so the
    /// hero screenshot formats dates and numbers the same on every
    /// contributor's Mac.
    private static func locale(for language: AppLanguage, sources: AppLanguageSources) -> Locale {
        language.resolvedLocale(
            preferredLanguages: sources.systemPreferredLanguages(),
            base: DemoFixture.isDemoActive ? Locale(identifier: "en") : sources.currentLocale()
        )
    }

    private func applyAppleLanguages(for lang: AppLanguage) {
        let key = "AppleLanguages"
        if let value = lang.appleLanguagesValue {
            languageSources.defaults.set(value, forKey: key)
        } else {
            languageSources.defaults.removeObject(forKey: key)
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
        Self.settingsFileURL(in: directory)
    }

    /// JSON file location for the production install. Used by callers
    /// that hint at the file path without holding a store reference
    /// (e.g. `GhosttyConfigBridge.makeConfigString`).
    static var defaultSettingsFileURL: URL {
        settingsFileURL(in: LimpidPaths.applicationSupportDirectory())
    }

    /// The settings file inside `directory`. Loading, saving, the file
    /// watcher, and moving an unreadable file aside all find the file
    /// through here, so they cannot end up on different files. The name
    /// is the one users edit by hand and the one older builds read, so
    /// it must not change.
    private static func settingsFileURL(in directory: URL) -> URL {
        directory.appendingPathComponent("settings.json")
    }

    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL, languageSources: AppLanguageSources = .live) {
        self.directory = directory
        self.languageSources = languageSources
        let raw = languageSources.defaults.string(forKey: Self.appLanguageDefaultsKey)
            ?? AppLanguage.system.rawValue
        let stored = AppLanguage(rawValue: raw) ?? .system
        // Demo mode pins the SwiftUI tree to English so the README hero
        // screenshot reads the same regardless of the contributor's OS
        // locale. UserDefaults stays untouched so the user's real
        // preference survives a `LIMPID_DEMO=1` run. AppKit menu bar
        // still follows `AppleLanguages` (untouched here) — capture
        // pipelines crop to the SwiftUI window content.
        let language = DemoFixture.isDemoActive ? AppLanguage.english : stored
        self.appLanguage = language
        self.appLocale = Self.locale(for: language, sources: languageSources)
        var loaded = Self.loadFromDiskOrDefault(at: Self.settingsFileURL(in: directory))
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
            // Same reason as the accent: `.system` would render the
            // hero in whichever appearance the contributor's Mac
            // happens to be in, so the README image would flip between
            // light and dark depending on who regenerated it.
            loaded.appearance.colorScheme = .light
            // Pinned for the same reason, and it has to be pinned in
            // both directions: this setting is opt-in, so without it
            // the hero would show the sidebar's request marks only for
            // contributors who happen to have switched them on. The
            // data behind them comes from `DemoFixture.prStatus`, not
            // from a CLI — see `PRStatusSyncer.start()`.
            loaded.advanced.showPRStatusInSidebar = true
            loaded.advanced.showPRStatusOnlyWhenAttention = false
        }
        self.settings = loaded
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAppLocale()
            }
        }
    }

    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
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
            // path.
            SecureFileWrite.quarantine(url, reason: "decode-failed")
            return .default
        }
    }

    /// Moves `settings.json` aside so the next launch starts from
    /// defaults. For the libghostty init-failure screen: the running
    /// `GhosttyApp` is already half-initialized, so the reset only takes
    /// effect on relaunch.
    static func moveSettingsFileAside(at url: URL = defaultSettingsFileURL) {
        SecureFileWrite.quarantine(url, reason: "init-failure")
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
        // Demo mode pins appearance and advanced values so the hero
        // screenshot does not depend on the contributor's own
        // preferences. Those pins are for the run, not for the file:
        // `make screenshot` quits the app through
        // `applicationWillTerminate`, and without this guard every
        // capture wrote them into the real `settings.json` — the same
        // file the installed build reads, since demo mode does not
        // change the bundle identifier. `SessionStore` guards both of
        // its write paths for the same reason; this is the one that
        // was missing.
        guard !DemoFixture.isDemoActive else { return }
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

/// The inputs the app language is resolved from. `live` reads and writes
/// the real preferences; tests pass their own so the host Mac's language
/// list never decides a result and nothing is written to `~/Library`.
struct AppLanguageSources {
    /// Where the picker's choice and the `AppleLanguages` mirror live.
    var defaults: UserDefaults
    /// The OS-wide preferred language list `.system` follows.
    var systemPreferredLanguages: () -> [String]
    /// The user's own locale, whose region and format choices are kept.
    var currentLocale: () -> Locale

    static var live: Self {
        Self(
            defaults: .standard,
            systemPreferredLanguages: AppLanguage.systemPreferredLanguages,
            currentLocale: { .current }
        )
    }
}
