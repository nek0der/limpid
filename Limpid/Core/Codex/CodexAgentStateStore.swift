// CodexAgentStateStore.swift
// Limpid — read / write / scan / cleanup for the per-pane Codex agent
// state records written by `codex-shim/limpid-codex-hook` on every
// relevant hook event. Mirrors `ClaudeAgentStateStore` shape.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "codex.agent.state.store")

final class CodexAgentStateStore {
    let directory: URL
    private let maxRecords: Int

    convenience init() {
        self.init(
            directory: LimpidPaths.applicationSupportDirectory()
                .appendingPathComponent("codex-agent-states", isDirectory: true)
        )
    }

    init(directory: URL, maxRecords: Int = 200) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.directory = directory
        self.maxRecords = maxRecords
    }

    // MARK: - Read

    func record(forPaneID paneID: UUID) -> CodexAgentStateRecord? {
        let url = fileURL(for: paneID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CodexAgentStateRecord.self, from: data)
        } catch {
            log.error("decode \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func allRecords() -> [CodexAgentStateRecord] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var out: [CodexAgentStateRecord] = []
        out.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".state.json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".state.json".count))
            guard UUID(uuidString: stem) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let rec = try? JSONDecoder().decode(CodexAgentStateRecord.self, from: data) else { continue }
            guard rec.paneId == stem else { continue }
            out.append(rec)
        }
        return out
    }

    // MARK: - Write / delete

    func save(_ record: CodexAgentStateRecord) throws {
        guard UUID(uuidString: record.paneId) != nil else {
            throw NSError(
                domain: "dev.limpid.codex.agent.state.store",
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

    func delete(paneID: UUID) {
        let url = fileURL(for: paneID)
        try? FileManager.default.removeItem(at: url)
    }

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
