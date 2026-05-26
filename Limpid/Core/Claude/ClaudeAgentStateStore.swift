// ClaudeAgentStateStore.swift
// Limpid — read / write / scan / cleanup for the per-pane Claude
// agent state records written by `claude-shim/limpid-hook` on every
// relevant hook event. Same shape as `ClaudeSessionStore` so tests
// inject an isolated directory via `init(directory:)` and production
// callers use the no-arg `init()`.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.agent.state.store")

final class ClaudeAgentStateStore {
    /// Absolute URL of the directory we manage. Files inside are
    /// named `<pane-uuid>.state.json`; everything else is ignored
    /// on scan.
    let directory: URL

    /// Hard cap on retained records. The cleanup pass keeps newest
    /// by mtime; agent state is ephemeral so we don't need a deep
    /// history.
    private let maxRecords: Int

    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("agent-states", isDirectory: true)
        )
    }

    init(directory: URL, maxRecords: Int = 200) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.directory = directory
        self.maxRecords = maxRecords
    }

    // MARK: - Read

    /// Load the record for `paneID` from disk, or `nil` if the file
    /// is missing / unreadable / malformed.
    func record(forPaneID paneID: UUID) -> ClaudeAgentStateRecord? {
        let url = fileURL(for: paneID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(ClaudeAgentStateRecord.self, from: data)
        } catch {
            log.error("decode \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Enumerate every well-formed record under `directory`. Files
    /// that don't match `<uuid>.state.json` or fail to decode are
    /// skipped silently — the hook may have written them mid-update
    /// and the next event will rewrite cleanly.
    func allRecords() -> [ClaudeAgentStateRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var out: [ClaudeAgentStateRecord] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".state.json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".state.json".count))
            guard UUID(uuidString: stem) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let rec = try? JSONDecoder().decode(ClaudeAgentStateRecord.self, from: data) else { continue }
            // Defense in depth: filename must match payload's paneId.
            guard rec.paneId == stem else { continue }
            out.append(rec)
        }
        return out
    }

    // MARK: - Write / delete

    /// Persist `record` for its `paneId`. Atomic via `SecureFileWrite`.
    /// Swift-side callers use this for tests; production writes come
    /// from the shell hook directly.
    func save(_ record: ClaudeAgentStateRecord) throws {
        guard UUID(uuidString: record.paneId) != nil else {
            throw NSError(
                domain: "dev.limpid.claude.agent.state.store",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid paneId: \(record.paneId)"]
            )
        }
        let url = directory.appendingPathComponent("\(record.paneId).state.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(record)
        try SecureFileWrite.writeAtomic(data, to: url)
    }

    /// Delete the on-disk record for `paneID`. Missing files are not
    /// an error — pane close routinely fires this regardless of
    /// whether claude was ever launched in that pane.
    func delete(paneID: UUID) {
        let url = fileURL(for: paneID)
        try? FileManager.default.removeItem(at: url)
    }

    /// Drop records whose `paneId` is not in `alivePaneIDs`, then
    /// cap the survivors at `maxRecords` (newest by mtime wins).
    func cleanup(keeping alivePaneIDs: Set<UUID>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }

        struct Entry {
            let url: URL
            let paneID: UUID?
            let mtime: Date
        }
        var entries: [Entry] = []
        entries.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".state.json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".state.json".count))
            let paneID = UUID(uuidString: stem)
            let url = directory.appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? .distantPast
            entries.append(Entry(url: url, paneID: paneID, mtime: mtime))
        }

        var surviving: [Entry] = []
        surviving.reserveCapacity(entries.count)
        for e in entries {
            if let id = e.paneID, alivePaneIDs.contains(id) {
                surviving.append(e)
            } else {
                try? fm.removeItem(at: e.url)
            }
        }

        guard surviving.count > maxRecords else { return }
        surviving.sort { $0.mtime > $1.mtime }
        for victim in surviving[maxRecords...] {
            try? fm.removeItem(at: victim.url)
        }
    }

    // MARK: - Internal

    private func fileURL(for paneID: UUID) -> URL {
        directory.appendingPathComponent("\(paneID.uuidString).state.json")
    }
}
