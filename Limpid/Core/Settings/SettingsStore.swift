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

    /// The language this launch began with, which the macOS menu bar keeps
    /// until the next one.
    let appLanguageAtLaunch: AppLanguage

    /// Whether the menu bar still shows another language than the one
    /// chosen, which only a relaunch changes (General offers it).
    var needsRelaunchForLanguage: Bool {
        appLanguage != appLanguageAtLaunch
    }

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
            // A change made here (a reset, a new hotkey, Restore Defaults)
            // can free or take a default's keys, so the bindings are put
            // back in line before anything reads or saves them.
            var normalized = settings
            normalized.normalizeKeyboard()
            if normalized != settings {
                settings = normalized
            }
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

    /// False in demo mode: nothing this store does reaches the file.
    @ObservationIgnored
    private let writesFiles: Bool

    /// See `LoadResult.suspendsSaving`.
    @ObservationIgnored
    private var isSavingSuspended = false

    /// Why saving stopped, for the notice at the top of Settings → General
    /// (`SavingSuspendedNotice`), which tells the person their settings are
    /// not being saved. `nil` while they are, and in demo mode, which saves
    /// nothing anyway. Observed, so a file fixed by hand and read again
    /// (`reloadFromDisk`) takes the notice down.
    private(set) var savingSuspension: SettingsSavingSuspension?

    /// See `LoadResult.pendingMigration`.
    @ObservationIgnored
    private var pendingMigration: MigrationBackupRecord?

    /// The bytes the file held when we last met it: what our last save
    /// wrote, or what our last reload read. The file watcher reports a save
    /// like any other change, about 200 ms later; a change made in that
    /// time, not yet saved, would be replaced by what the file still holds.
    /// A reload that finds these bytes has nothing new and leaves the
    /// settings alone. Taken from a reload too, so a hand edit back to what
    /// we saved before is new to us and read. `nil` until the first of them.
    @ObservationIgnored
    private var lastSyncedBytes: Data?

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

    /// `writesFiles` comes from the app, which decides once for every store
    /// whether this run may write the person's files (not in demo mode).
    convenience init(writesFiles: Bool) {
        self.init(directory: LimpidPaths.applicationSupportDirectory(), writesFiles: writesFiles)
    }

    /// `writesFiles` is false in demo mode, whose pins and in-memory
    /// migration are for the run, not for the file (see `saveNow`).
    init(
        directory: URL,
        languageSources: AppLanguageSources = .live,
        writesFiles: Bool = true
    ) {
        self.directory = directory
        self.languageSources = languageSources
        self.writesFiles = writesFiles
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
        self.appLanguageAtLaunch = language
        self.appLocale = Self.locale(for: language, sources: languageSources)
        let result = Self.load(at: Self.settingsFileURL(in: directory), writes: writesFiles)
        var loaded = result.settings
        self.isSavingSuspended = result.suspendsSaving
        self.savingSuspension = writesFiles ? result.suspension : nil
        self.pendingMigration = result.pendingMigration
        // The launch's own move to the current schema, should the watcher
        // report it, is nothing new (`reloadFromDisk`).
        self.lastSyncedBytes = result.writtenBytes
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
            // The default family at 12 points: the hero's 1440-point window
            // fits the sidebar, a 100-column terminal, and the changes
            // panel side by side only at that size, and a contributor's
            // own font would move every column.
            loaded.font = FontSettings()
            loaded.font.size = 12
            // A Ghostty config file would set its own `font-family` over
            // the default one, so the demo reads none.
            loaded.advanced.ghosttyConfig = .off
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

    /// What loading `settings.json` gave.
    private struct LoadResult {
        var settings: LimpidSettings
        /// A move whose copy and ledger exist but whose write failed: the
        /// first save that reaches disk finishes it (`finishPendingMigration`).
        var pendingMigration: MigrationBackupRecord?
        /// Saving would replace a file this launch did not take in: one
        /// that could not be read and could not be moved aside, an older
        /// one read as it was because its move to the current schema could
        /// not be made safely, or one a newer build wrote. Saving stops
        /// for the launch.
        var suspendsSaving = false
        /// Why, when `suspendsSaving`.
        var suspension: SettingsSavingSuspension?
        /// Whether `settings` are the file's own, decoded as it stands
        /// (`decodeAsWritten`), rather than the defaults that replace a
        /// file that does not decode.
        var isDecoded = false
        /// This is what the load wrote over the file, when it moved it to the
        /// current schema and the write landed: the file now holds these
        /// bytes, not the ones read (`lastSyncedBytes`).
        var writtenBytes: Data?
    }

    /// The settings in `url`, moved to the current schema when they are
    /// older and kept consistent with this build's keys on every load
    /// (`LimpidSettings.normalizeKeyboard`). With `writes` false (demo
    /// mode) nothing is written: the move happens in memory only.
    private static func load(at url: URL, writes: Bool) -> LoadResult {
        var result = loadAsStored(at: url, writes: writes)
        result.settings.normalizeKeyboard()
        return result
    }

    private static func loadAsStored(at url: URL, writes: Bool) -> LoadResult {
        // Only a file that is not there is a first launch. A check that the
        // file exists would also answer no for a folder that cannot be
        // searched, and the defaults would then be saved over the file once
        // the folder opens up again.
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            log.info("settings.json absent at \(url.path, privacy: .private); using defaults")
            return LoadResult(settings: .default)
        } catch {
            log.error("settings.json read failed: \(String(describing: error), privacy: .private). Using defaults.")
            return setAsideUnread(url, writes: writes)
        }
        let outcome: VersionedDocumentMigrator.Outcome
        do {
            outcome = try VersionedDocumentMigrator.settings.migrate(data)
        } catch {
            // The file is read as it was and not written; the next launch
            // tries again.
            log.error("settings.json migration failed: \(String(describing: error), privacy: .private)")
            return readWithoutMigrating(data, at: url, writes: writes)
        }
        switch outcome {
        case let .migrated(from, migrated):
            return loadMigrated(original: data, migrated: migrated, from: from, at: url, writes: writes)
        case .current:
            if writes {
                MigrationBackup.finishIfWritten(url, current: data, version: LimpidSettings.currentSchemaVersion)
            }
            return decodeAsWritten(data, at: url, writes: writes)
        case let .newer(found):
            // Kept and read, not set aside: a rollback must not cost the
            // person their settings. Not written back either: a save
            // would write this build's schema under the newer version
            // number, and the newer build, seeing its own number, would
            // skip the step that moves a value to where it now lives.
            log.notice("settings.json schema v\(found, privacy: .public) is newer; reading it without saving")
            return readNewer(data)
        case .unsupported, .unreadableVersion:
            return decodeAsWritten(data, at: url, writes: writes)
        }
    }

    /// Keeps a copy of the old file (`settings.json.pre-v2`), then writes
    /// the migrated one at once, as `SessionStore` does for `state.json`.
    /// Without a copy the file is read as it was and not written, so the
    /// next launch tries again rather than replacing the only one.
    private static func loadMigrated(
        original: Data,
        migrated: Data,
        from: Int,
        at url: URL,
        writes: Bool
    ) -> LoadResult {
        let settings: LimpidSettings
        let encoded: Data
        do {
            settings = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: migrated)
            encoded = try LimpidSettings.makeFileEncoder().encode(settings)
        } catch {
            log.error("migrated settings do not decode or encode: \(String(describing: error), privacy: .private)")
            return readWithoutMigrating(original, at: url, writes: writes)
        }
        // Demo mode moves the settings in memory only: the file belongs to
        // the build the person runs, which may be an older one.
        guard writes else { return LoadResult(settings: settings) }
        let record: MigrationBackupRecord
        do {
            record = try MigrationBackup.keep(
                url,
                source: original,
                migrated: encoded,
                from: from,
                to: LimpidSettings.currentSchemaVersion
            )
        } catch {
            log.error("settings.json backup failed: \(String(describing: error), privacy: .private)")
            return readWithoutMigrating(original, at: url, writes: writes)
        }
        do {
            try SecureFileWrite.writeAtomic(encoded, to: url)
        } catch {
            // The migrated settings are in use and the next save writes
            // them; that save finishes the ledger with the bytes it writes,
            // which are not the ones recorded.
            log.error("migrated settings.json write failed: \(String(describing: error), privacy: .private)")
            return LoadResult(settings: settings, pendingMigration: record)
        }
        log.notice("migrated settings.json from v\(from, privacy: .public)")
        do {
            try MigrationBackup.markWritten(record, for: url)
        } catch {
            // The file is on disk; only the ledger lags. A relaunch finishes
            // the ledger from the bytes on disk.
            log.error("settings migration ledger update failed: \(String(describing: error), privacy: .private)")
        }
        return LoadResult(settings: settings, writtenBytes: encoded)
    }

    /// An older file read as it stands because its move could not be made
    /// safely. Saving stops for the launch: a save would write this
    /// build's schema over the only copy of the old one, and the copy kept
    /// on the next launch would no longer be what the person had. A file
    /// that does not decode either is not read as it stands: it goes the
    /// way of any file that does not decode (`decodeAsWritten`), and
    /// saving stops only if it could not be moved aside.
    private static func readWithoutMigrating(_ data: Data, at url: URL, writes: Bool) -> LoadResult {
        var result = decodeAsWritten(data, at: url, writes: writes)
        guard result.isDecoded else { return result }
        result.suspendsSaving = true
        result.suspension = .notMoved
        return result
    }

    /// A file a newer build wrote, read where it is. Saving stops whether
    /// it decodes or not, so it is decided before the decode. One that does
    /// not decode (the newer build changed the type of a key this build
    /// knows) is still that build's file: it is not set aside, which would
    /// leave the newer build its defaults on the way back, and this launch
    /// runs on the defaults in memory.
    private static func readNewer(_ data: Data) -> LoadResult {
        do {
            let settings = try PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data)
            return LoadResult(settings: settings, suspendsSaving: true, suspension: .newerVersion, isDecoded: true)
        } catch {
            log.error("newer settings.json does not decode: \(String(describing: error), privacy: .private). Using defaults.")
            return LoadResult(settings: .default, suspendsSaving: true, suspension: .newerVersionUnreadable)
        }
    }

    /// Moves a file this launch cannot take in out of the way, so the next
    /// save lands on a fresh path; when it cannot be moved, saving stops
    /// instead of replacing it with defaults.
    private static func setAside(_ url: URL, reason: String, writes: Bool) -> LoadResult {
        guard writes else { return LoadResult(settings: .default) }
        let suspendsSaving = SecureFileWrite.setAside(url, reason: reason) == .keptInPlace
        if suspendsSaving {
            log.error("settings.json stays in place; saving is suspended for this launch")
        }
        return LoadResult(settings: .default, suspendsSaving: suspendsSaving, suspension: suspendsSaving ? .unreadable : nil)
    }

    /// `setAside` for a file that could not be read. Saving goes on only
    /// once the file has actually moved: `setAside` counts a file it cannot
    /// see as cleared, and an unreadable folder hides the file it holds.
    private static func setAsideUnread(_ url: URL, writes: Bool) -> LoadResult {
        guard writes else { return LoadResult(settings: .default) }
        guard SecureFileWrite.quarantine(url, reason: "read-failed") == nil else { return LoadResult(settings: .default) }
        log.error("unreadable settings.json stays in place; saving is suspended for this launch")
        return LoadResult(settings: .default, suspendsSaving: true, suspension: .unreadable)
    }

    /// The file decoded as it stands, or the defaults when it does not
    /// decode.
    private static func decodeAsWritten(_ data: Data, at url: URL, writes: Bool) -> LoadResult {
        do {
            return try LoadResult(settings: PersistenceCoders.makeDecoder().decode(LimpidSettings.self, from: data), isDecoded: true)
        } catch {
            log.error("settings.json decode failed: \(String(describing: error), privacy: .private). Using defaults.")
            // settings.json is the one file we document as user-editable
            // (the prettyPrinted carve-out in saveNow). A stray comma in
            // a hand edit must not destroy the rest of the file on the
            // next mutation — didSet → scheduleSave would otherwise
            // atomic-replace the bad bytes with defaults.
            return setAside(url, reason: "decode-failed", writes: writes)
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
        guard writesFiles, !isSavingSuspended else { return }
        let url = settingsFileURL
        SecureFileWrite.ensureUserOnlyDirectory(url.deletingLastPathComponent())
        do {
            // `PersistenceCoders.makeEncoder` skips `.prettyPrinted` in
            // Release; `settings.json` is the one file the user is
            // expected to open in an editor, so override that and keep
            // the file pretty in every build.
            let data = try LimpidSettings.makeFileEncoder().encode(settings)
            // Same 0600 path as `state.json` / `notifications.json` —
            // `settings.json` may not carry secrets today but it's
            // still the user's machine-local prefs file and shouldn't
            // ship out with the default 0644.
            try SecureFileWrite.writeAtomic(data, to: url)
            lastSyncedBytes = data
            finishPendingMigration(written: data, at: url)
        } catch {
            log.error("settings.json save failed: \(String(describing: error), privacy: .private)")
        }
    }

    /// The migrated settings reached disk through an ordinary save: the
    /// ledger records those bytes as written. If the save lands and only
    /// the ledger fails, and the app then quits, the ledger keeps the
    /// migration's own hash and stays at `backedUp`; the copy is still
    /// there, and the ledger is tried again on every save until then.
    private func finishPendingMigration(written data: Data, at url: URL) {
        guard let pendingMigration else { return }
        do {
            try MigrationBackup.markWritten(pendingMigration, for: url, bytes: data)
            self.pendingMigration = nil
        } catch {
            // Tried again on the next save.
            log.error("settings migration ledger update failed: \(String(describing: error), privacy: .private)")
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
        // Our own save coming back through the watcher, or a file unchanged
        // since we last read it: nothing we do not already have, and the
        // settings may have moved on since. A read that fails is not one
        // and goes the usual way.
        let bytes = try? Data(contentsOf: settingsFileURL)
        if let lastSyncedBytes, bytes == lastSyncedBytes {
            return
        }
        let result = Self.load(at: settingsFileURL, writes: writesFiles)
        // A move to the current schema writes the file again, and the
        // watcher reports that write as well: those bytes are what the file
        // holds now, and a change made before it reports must not be
        // replaced by them. A write that failed leaves the bytes read.
        lastSyncedBytes = result.writtenBytes ?? bytes
        // A file fixed by hand since the launch takes saving back up.
        isSavingSuspended = result.suspendsSaving
        let suspension = writesFiles ? result.suspension : nil
        if savingSuspension != suspension {
            savingSuspension = suspension
        }
        // What this reload left unfinished, or nothing: a move this reload
        // wrote must not be overwritten by the record of an earlier one.
        pendingMigration = result.pendingMigration
        let fresh = result.settings
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

/// Why `settings.json` is not being saved for this launch.
enum SettingsSavingSuspension: Equatable {
    /// It could not be read and could not be moved aside.
    case unreadable
    /// It is an older file, read as it stands, whose move to this version's
    /// format could not be made safely.
    case notMoved
    /// A newer build wrote it. It is read, and left for that build.
    case newerVersion
    /// A newer build wrote it in a form this build cannot decode. It is
    /// left for that build, and this launch runs on the defaults.
    case newerVersionUnreadable
}
