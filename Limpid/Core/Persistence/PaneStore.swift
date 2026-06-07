// PaneStore.swift
// Limpid — generic read / write / scan / cleanup for the per-pane
// directory stores written by the Claude and Codex shim hooks. Five
// stores used to carry near-identical copies of `record(forPaneID:)`
// / `allRecords()` / `save(_:)` / `delete(paneID:)` /
// `cleanup(keeping:)` plus a shared `Entry` struct for the mtime cap;
// each one diverged in directory name (`sessions`, `agent-states`,
// `codex-sessions`, `codex-agent-states`, `cwd-events`), file suffix
// (`.json`, `.state.json`, `.cwd.json`), and log category.
//
// `PaneStore<Record>` takes those three as init params and exposes the
// common API; each concrete store becomes a `typealias` plus a
// `convenience init()` extension supplying the production directory.
// Tests still inject an isolated directory via the designated
// `init(directory:maxRecords:)` so writes never touch the user's
// Application Support folder.

import Foundation
import OSLog

/// On-disk record that knows which pane it belongs to. The hook
/// scripts write the `paneId` as a String (shell-friendly UUID round
/// trip) and `PaneStore.allRecords()` cross-checks it against the
/// filename so a tampered or partial write doesn't slip through.
protocol PaneScopedRecord: Codable {
    var paneId: String { get }
}

final class PaneStore<Record: PaneScopedRecord> {
    /// Absolute URL of the directory we manage. Files inside are
    /// named `<pane-uuid><suffix>`; everything else is ignored.
    let directory: URL
    private let maxRecords: Int
    private let fileSuffix: String
    private let log: Logger
    /// Reused coders so `allRecords()` / `save(_:)` don't allocate a
    /// fresh `JSONDecoder` per file on every FSEvent fire. Hook
    /// scripts (Claude / Codex) burst-write enough entries to make
    /// per-call allocation visible on a busy turn.
    private let decoder: JSONDecoder = PersistenceCoders.makeDecoder()
    private let encoder: JSONEncoder = {
        let enc = PersistenceCoders.makeEncoder()
        enc.outputFormatting.insert(.sortedKeys)
        return enc
    }()

    init(
        directory: URL,
        maxRecords: Int,
        fileSuffix: String,
        logCategory: String
    ) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.directory = directory
        self.maxRecords = maxRecords
        self.fileSuffix = fileSuffix
        self.log = Logger.limpid(logCategory)
    }

    // MARK: - Read

    /// Load the record for `paneID`, or nil if the file is missing /
    /// unreadable / malformed. Malformed files are left in place so we
    /// can inspect them after the fact.
    func record(forPaneID paneID: UUID) -> Record? {
        let url = fileURL(for: paneID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decoder.decode(Record.self, from: data)
        } catch {
            log.error("decode \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Enumerate every well-formed record under `directory`. Files
    /// that don't match `<uuid><suffix>` or fail to decode are skipped
    /// silently — the hook may have written them mid-update; the next
    /// event will rewrite cleanly.
    func allRecords() -> [Record] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var out: [Record] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard let (stem, url) = parseFilename(name) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let rec = try? decoder.decode(Record.self, from: data) else { continue }
            // Defense in depth: filename UUID must match the payload's
            // paneId. A mismatch indicates a tampered or partial write.
            guard rec.paneId == stem else { continue }
            out.append(rec)
        }
        return out
    }

    // MARK: - Write / delete

    /// Persist `record` for its `paneId`. Used by Swift-side callers
    /// (the hook script writes the same file shape on its own path).
    /// Atomic via `SecureFileWrite.writeAtomic`.
    func save(_ record: Record) throws {
        guard UUID(uuidString: record.paneId) != nil else {
            throw NSError(
                domain: "dev.limpid.persistence.pane-store",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid paneId: \(record.paneId)"]
            )
        }
        let url = directory.appendingPathComponent("\(record.paneId)\(fileSuffix)")
        let data = try encoder.encode(record)
        try SecureFileWrite.writeAtomic(data, to: url)
    }

    /// Delete the on-disk record for `paneID`. Missing files are not
    /// an error — the caller fires this on tab / pane close regardless
    /// of whether the agent was ever launched in that pane.
    func delete(paneID: UUID) {
        let url = fileURL(for: paneID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop records whose `paneId` is not in `alivePaneIDs`, then cap
    /// the remaining count at `maxRecords` (newest by mtime wins).
    func cleanup(keeping alivePaneIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }

        // Collect candidates with mtime up front so the orphan + cap
        // passes share one stat per file.
        var entries: [PaneStoreCleanupEntry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(fileSuffix), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(fileSuffix.count))
            let paneID = UUID(uuidString: stem)
            let url = directory.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            entries.append(PaneStoreCleanupEntry(url: url, paneID: paneID, mtime: mtime))
        }

        // Pass 1: drop anything whose pane is gone (or whose filename
        // doesn't even parse as a UUID).
        var surviving: [PaneStoreCleanupEntry] = []
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
        directory.appendingPathComponent("\(paneID.uuidString)\(fileSuffix)")
    }

    /// Parse `name` as `<uuid><fileSuffix>`. Returns the stem (also
    /// the expected `paneId` payload) and the absolute URL when the
    /// shape matches. Used by `allRecords` to share one parse pass.
    private func parseFilename(_ name: String) -> (stem: String, url: URL)? {
        guard name.hasSuffix(fileSuffix), !name.hasPrefix(".") else { return nil }
        let stem = String(name.dropLast(fileSuffix.count))
        guard UUID(uuidString: stem) != nil else { return nil }
        return (stem, directory.appendingPathComponent(name))
    }
}

/// File-scoped helper for `cleanup(keeping:)`. Lifted out of the
/// generic method body because Swift disallows nested types inside
/// generic functions.
private struct PaneStoreCleanupEntry {
    let url: URL
    let paneID: UUID?
    let mtime: Date
}
