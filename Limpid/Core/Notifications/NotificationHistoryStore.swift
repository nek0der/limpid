// NotificationHistoryStore.swift
// Limpid — keeps the recent-notifications list in memory and on disk.
//
// One @Observable singleton drives the toolbar bell button (popover
// presentation state) and the rolling notifications.json file. We keep
// up to `maxEntries` rows; the oldest fall off the end when new
// entries arrive.

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

    /// Number of unread entries — surfaces as the toolbar bell badge.
    var unreadCount: Int {
        entries.lazy.count(where: { !$0.isRead })
    }

    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "dev.limpid.notifications.history")

    /// Production callers use the no-arg `init()`; tests pass an
    /// isolated temp directory via `init(directory:)` so they don't
    /// clobber the user's real notifications.json. The override is
    /// internal-only — production code should never call it.
    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.fileURL = directory.appendingPathComponent("notifications.json")
        load()
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

    /// Mark every unread entry whose `paneID` is in `paneIDs` as read.
    /// Called when the user navigates to a tab — viewing the source
    /// session should naturally clear the matching history dots so
    /// the popover doesn't accumulate stale unread indicators after
    /// the user has already seen the activity.
    func markRead(forPanes paneIDs: Set<UUID>) {
        guard !paneIDs.isEmpty else { return }
        var changed = false
        for i in entries.indices {
            guard !entries[i].isRead,
                  let pid = entries[i].paneID,
                  paneIDs.contains(pid)
            else { continue }
            entries[i].isRead = true
            changed = true
        }
        if changed { scheduleSave() }
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
        pendingSave?.cancel()
        pendingSave = nil
        let snapshot = entries
        let url = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: url)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = PersistenceCoders.makeDecoder()
            entries = try decoder.decode([NotificationEntry].self, from: data)
        } catch {
            log.error("failed to decode notifications.json: \(String(describing: error), privacy: .public)")
            // A subsequent `record` / `markRead` would otherwise debounce
            // a write of the empty `entries` array and destroy the bad-
            // but-maybe-recoverable file. Move it aside first.
            let ts = Int(Date().timeIntervalSince1970)
            let bak = fileURL.deletingLastPathComponent()
                .appendingPathComponent("notifications.json.bak-\(ts)")
            do {
                try FileManager.default.moveItem(at: fileURL, to: bak)
                log.notice("quarantined notifications to \(bak.lastPathComponent, privacy: .public)")
            } catch {
                log.error("failed to quarantine notifications: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let snapshot = entries
        let url = fileURL
        let work = DispatchWorkItem { [saveQueue] in
            saveQueue.async {
                Self.write(snapshot, to: url)
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(PersistenceTiming.coalescingMs),
            execute: work
        )
    }

    private nonisolated static func write(_ entries: [NotificationEntry], to url: URL) {
        do {
            let encoder = PersistenceCoders.makeEncoder()
            let data = try encoder.encode(entries)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("failed to write notifications.json: \(String(describing: error), privacy: .public)")
        }
    }
}
