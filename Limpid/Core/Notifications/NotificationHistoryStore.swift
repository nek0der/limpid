// NotificationHistoryStore.swift
// Limpid — keeps the recent-notifications list in memory and on disk.
//
// One @Observable store drives every window's history panel and the
// rolling notifications.json file. We keep up to `maxEntries` rows; the
// oldest fall off the end when new entries arrive.

import Foundation
import Observation
import OSLog

private let log = Logger.limpid("notifications.history")

@MainActor
@Observable
final class NotificationHistoryStore {
    /// Bounded to keep file IO and SwiftUI list rendering cheap. Tune
    /// later if user feedback suggests a deeper history is useful.
    private let maxEntries = 500

    /// Newest first.
    private(set) var entries: [NotificationEntry] = []

    /// Number of unread entries — surfaces as the rail button's badge and
    /// the Unread filter's count.
    var unreadCount: Int {
        entries.lazy.count(where: { !$0.isRead })
    }

    /// Whether an unread entry came from a command rather than an agent
    /// (OSC 9 / 777, a long command finishing). The attention list counts
    /// the agents' news; this is what the Dock dot stands for instead.
    var hasUnreadCommandEntries: Bool {
        entries.contains { !$0.isRead && $0.kind.isFromACommand }
    }

    private let fileURL: URL
    private let saveDebounce = DebouncedSave()
    /// An unreadable notifications.json could not be moved aside; saving
    /// would replace it with what this launch records, so it stops.
    private var isSavingSuspended = false
    /// False in demo mode: the history starts empty and stays in memory.
    /// The file belongs to the build the person runs, which demo mode
    /// shares (`SettingsStore.writesFiles`), and its rows (real paths and
    /// prompts) must not reach a demo's screenshot.
    private let writesFiles: Bool
    private let saveQueue = DispatchQueue(label: "dev.limpid.notifications.history")

    /// The app builds it with `init(writesFiles:)`, its own decision for
    /// every store; tests pass an isolated temp directory via
    /// `init(directory:)` so they don't clobber the user's real
    /// notifications.json.
    convenience init(writesFiles: Bool) {
        self.init(directory: LimpidPaths.applicationSupportDirectory(), writesFiles: writesFiles)
    }

    init(directory: URL, writesFiles: Bool = true) {
        self.writesFiles = writesFiles
        if writesFiles {
            SecureFileWrite.ensureUserOnlyDirectory(directory)
        }
        self.fileURL = directory.appendingPathComponent("notifications.json")
        if writesFiles {
            load()
        }
    }

    // MARK: - Mutations

    func record(_ entry: NotificationEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        scheduleSave()
    }

    func markRead(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        guard !entries[idx].isRead else { return }
        entries[idx].isRead = true
        scheduleSave()
    }

    func markAllRead() {
        guard entries.contains(where: { !$0.isRead }) else { return }
        for i in entries.indices {
            entries[i].isRead = true
        }
        scheduleSave()
    }

    /// Mark every unread non-agent entry whose `paneID` is in `paneIDs`
    /// as read. Agent rows are reconciled from their runtime episode;
    /// pane identity cannot prove that a background tmux pane was seen
    /// or that an input request was resolved.
    func markRead(forPanes paneIDs: Set<UUID>) {
        guard !paneIDs.isEmpty else { return }
        var changed = false
        for i in entries.indices {
            guard !entries[i].isRead,
                  let pid = entries[i].paneID,
                  paneIDs.contains(pid),
                  entries[i].kind.agentState == nil
            else { continue }
            entries[i].isRead = true
            changed = true
        }
        if changed {
            scheduleSave()
        }
    }

    /// Mark every unread entry satisfying `predicate` as read. Used by
    /// `NotificationReadSync` to retire agent rows whose runtime has
    /// moved on, so the unread count only counts what still needs the
    /// user. Saves only when something actually changed, which also
    /// keeps the observation loop (sync observes `entries`) quiet.
    func markRead(where predicate: (NotificationEntry) -> Bool) {
        var changed = false
        for i in entries.indices where !entries[i].isRead && predicate(entries[i]) {
            entries[i].isRead = true
            changed = true
        }
        if changed {
            scheduleSave()
        }
    }

    func clearAll() {
        guard !entries.isEmpty else { return }
        entries.removeAll()
        scheduleSave()
    }

    /// Remove a single entry from the history. Used by the per-row X
    /// button in the panel.
    func delete(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: idx)
        scheduleSave()
    }

    /// Write the current in-memory list to disk *now*, on the calling
    /// thread. Used from `applicationWillTerminate` so a notification
    /// received in the last ~400 ms (the debounce window) still lands
    /// on disk before the process exits.
    func flushSynchronously() {
        saveDebounce.cancel()
        guard writesFiles, !isSavingSuspended else { return }
        let snapshot = entries
        let url = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: url)
        }
    }

    // MARK: - Persistence

    private func load() {
        // No file yet is the first launch; a file that is there but cannot
        // be read is kept like one that does not decode.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            log.error("failed to read notifications.json: \(String(describing: error), privacy: .private)")
            setAside(reason: "read-failed")
            return
        }
        do {
            let decoder = PersistenceCoders.makeDecoder()
            entries = try decoder.decode([NotificationEntry].self, from: data)
        } catch {
            log.error("failed to decode notifications.json: \(String(describing: error), privacy: .private)")
            setAside(reason: "decode-failed")
        }
    }

    /// A subsequent `record` / `markRead` would otherwise debounce a write
    /// of the empty `entries` array and destroy the bad-but-maybe-
    /// recoverable file. Move it aside first, or stop saving when it
    /// cannot be moved.
    private func setAside(reason: String) {
        guard writesFiles else { return }
        if SecureFileWrite.setAside(fileURL, reason: reason) == .keptInPlace {
            log.error("notifications.json stays in place; saving is suspended for this launch")
            isSavingSuspended = true
        }
    }

    private func scheduleSave() {
        saveDebounce.cancel()
        guard writesFiles, !isSavingSuspended else { return }
        let snapshot = entries
        let url = fileURL
        saveDebounce.schedule { [saveQueue] in
            saveQueue.async {
                Self.write(snapshot, to: url)
            }
        }
    }

    private nonisolated static func write(_ entries: [NotificationEntry], to url: URL) {
        do {
            let encoder = PersistenceCoders.makeEncoder()
            let data = try encoder.encode(entries)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("failed to write notifications.json: \(String(describing: error), privacy: .private)")
        }
    }
}
