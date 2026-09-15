// FrecencyStore.swift
// Limpid — frequency + recency scoring for command palette items.
// Persisted to frecency.json with debounced writes following the
// same pattern as NotificationHistoryStore.

import Foundation
import OSLog

private let log = Logger.limpid("frecency")

@MainActor
final class FrecencyStore {

    struct Entry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// Half-life of 3 days. An action used 3 days ago retains ~50%
    /// of its recency weight; after 2 weeks it's near zero.
    private static let halfLifeSeconds: Double = 259_200
    private static let decayFactor: Double = 0.693 / halfLifeSeconds

    /// Entries untouched for this long are dropped on load and before
    /// each write. Against a 3-day half-life a 30-day-old entry keeps
    /// roughly 0.1% of its recency weight, so dropping it cannot move a
    /// ranking.
    ///
    /// This is eviction, not tidiness. Keys are per-object identities
    /// (`tab.<uuid>`, `worktree.<projectID>.<worktreeID>`, `reopen.<uuid>`,
    /// …), and closing a tab or deleting a worktree does not remove the
    /// row — nothing did. The map is also persisted and reloaded every
    /// launch, so without an age bound both `frecency.json` and the
    /// in-memory dictionary grow for the life of the install. Aging it
    /// out here keeps the bound inside the store, so call sites that
    /// destroy objects do not each have to remember to clean up.
    private static let entryLifetime: TimeInterval = 30 * 24 * 60 * 60

    private(set) var entries: [String: Entry] = [:]
    private let fileURL: URL
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "dev.limpid.frecency")

    convenience init() {
        self.init(directory: LimpidPaths.applicationSupportDirectory())
    }

    init(directory: URL) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.fileURL = directory.appendingPathComponent("frecency.json")
        load()
    }

    // MARK: - Scoring

    func score(for itemID: String, now: Date = .now) -> Double {
        guard let entry = entries[itemID] else { return 0 }
        let age = now.timeIntervalSince(entry.lastUsed)
        let recency = exp(-Self.decayFactor * max(age, 0))
        return Double(entry.count) * recency
    }

    // MARK: - Recording

    func record(_ itemID: String) {
        if var existing = entries[itemID] {
            existing.count += 1
            existing.lastUsed = .now
            entries[itemID] = existing
        } else {
            entries[itemID] = Entry(count: 1, lastUsed: .now)
        }
        scheduleSave()
    }

    // MARK: - Persistence

    func flushSynchronously() {
        pendingSave?.cancel()
        pendingSave = nil
        pruneExpired()
        let snapshot = entries
        let url = fileURL
        saveQueue.sync {
            Self.write(snapshot, to: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let decoder = PersistenceCoders.makeDecoder()
            entries = try decoder.decode([String: Entry].self, from: data)
            pruneExpired()
        } catch {
            log.error("failed to decode frecency.json: \(String(describing: error), privacy: .public)")
        }
    }

    /// Drop entries whose recency weight has decayed to nothing. Runs on
    /// load and before each write, which is often enough to bound the map
    /// and rare enough that the O(n) pass does not matter.
    private func pruneExpired(now: Date = .now) {
        let cutoff = now.addingTimeInterval(-Self.entryLifetime)
        entries = entries.filter { $0.value.lastUsed > cutoff }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        pruneExpired()
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

    private nonisolated static func write(_ entries: [String: Entry], to url: URL) {
        do {
            let encoder = PersistenceCoders.makeEncoder()
            let data = try encoder.encode(entries)
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("failed to write frecency.json: \(String(describing: error), privacy: .public)")
        }
    }
}
