// ClaudeSessionStore.swift
// Limpid — read/write/scan/cleanup for the per-pane Claude session
// records written by `claude-shim/limpid-hook`. Mirrors the
// `NotificationHistoryStore` shape so production callers use the
// no-arg `init()` and tests inject an isolated directory via
// `init(directory:)` to keep their writes out of the user's real
// Application Support folder.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.session.store")

final class ClaudeSessionStore {
    /// Absolute URL of the directory we manage. Files inside are named
    /// `<pane-uuid>.json`; everything else is ignored on scan.
    let directory: URL

    /// Hard cap on how many records we retain. The cleanup pass keeps
    /// the newest by mtime and drops older ones — Claude only knows
    /// how to resume the freshest session per cwd anyway, so a few
    /// hundred records is more than enough.
    private let maxRecords: Int

    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("sessions", isDirectory: true)
        )
    }

    init(directory: URL, maxRecords: Int = 200) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.directory = directory
        self.maxRecords = maxRecords
    }

    // MARK: - Read

    /// Load the record for `paneID` from disk, or `nil` if the file
    /// is missing / unreadable / malformed. Malformed files are left
    /// in place (not deleted) so we can inspect them after the fact.
    func record(forPaneID paneID: UUID) -> ClaudeSessionRecord? {
        let url = fileURL(for: paneID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ClaudeSessionRecord.self, from: data)
        } catch {
            log.error("decode \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Enumerate every well-formed record under `directory`. Files that
    /// don't match `<uuid>.json` or fail to decode are skipped silently
    /// (the hook may have written them mid-update; the next event will
    /// rewrite cleanly).
    func allRecords() -> [ClaudeSessionRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var out: [ClaudeSessionRecord] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".json".count))
            guard UUID(uuidString: stem) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let rec = try? JSONDecoder().decode(ClaudeSessionRecord.self, from: data) else { continue }
            // Defense in depth: the filename must match the payload's
            // paneId. A mismatch indicates a tampered or partial
            // write.
            guard rec.paneId == stem else { continue }
            out.append(rec)
        }
        return out
    }

    // MARK: - Write / delete

    /// Persist `record` for its `paneId`. Used by Swift-side callers
    /// (the hook script writes the same file shape on its own path).
    /// Atomic via `SecureFileWrite.writeAtomic`.
    func save(_ record: ClaudeSessionRecord) throws {
        guard UUID(uuidString: record.paneId) != nil else {
            throw NSError(
                domain: "dev.limpid.claude.session.store",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid paneId: \(record.paneId)"]
            )
        }
        let url = directory.appendingPathComponent("\(record.paneId).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(record)
        try SecureFileWrite.writeAtomic(data, to: url)
    }

    /// Delete the on-disk record for `paneID`. Missing files are not
    /// an error — the caller routinely fires this on tab/pane close
    /// regardless of whether claude was ever launched in that pane.
    func delete(paneID: UUID) {
        let url = fileURL(for: paneID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop records whose `paneId` is not in `alivePaneIDs`, then cap
    /// the remaining count at `maxRecords` (newest by mtime wins).
    /// Called from `ClaudeSessionTracker.bootstrap` after the snapshot
    /// has been restored so we don't ship orphan records forever.
    func cleanup(keeping alivePaneIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }

        // Collect candidates with mtime up front so the orphan + cap
        // passes share one stat per file.
        struct Entry {
            let url: URL
            let paneID: UUID?
            let mtime: Date
        }
        var entries: [Entry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".json".count))
            let paneID = UUID(uuidString: stem)
            let url = directory.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            entries.append(Entry(url: url, paneID: paneID, mtime: mtime))
        }

        // Pass 1: drop anything whose pane is gone (or whose filename
        // doesn't even parse as a UUID).
        var surviving: [Entry] = []
        surviving.reserveCapacity(entries.count)
        for e in entries {
            if let id = e.paneID, alivePaneIDs.contains(id) {
                surviving.append(e)
            } else {
                try? fm.removeItem(at: e.url)
            }
        }

        // Pass 2: cap. Drop oldest until we're at or under the cap.
        guard surviving.count > maxRecords else { return }
        surviving.sort { $0.mtime > $1.mtime }
        for victim in surviving[maxRecords...] {
            try? fm.removeItem(at: victim.url)
        }
    }

    // MARK: - Internal

    private func fileURL(for paneID: UUID) -> URL {
        directory.appendingPathComponent("\(paneID.uuidString).json")
    }
}
