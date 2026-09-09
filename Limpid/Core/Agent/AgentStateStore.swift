// AgentStateStore.swift
// Limpid — runtime-scoped persistence for agent lifecycle records.

import Foundation
import OSLog

/// A lifecycle record is keyed by one agent invocation when `runId` is
/// available. Legacy records fall back to their launch pane id so a running
/// agent from the previous app version can migrate on its next hook event.
final class AgentStateStore<Record: AgentLifecycleRecord> {
    let directory: URL
    private let maxRetiredRecords: Int
    private let log: Logger
    private let decoder = PersistenceCoders.makeDecoder()
    private let encoder: JSONEncoder = {
        let encoder = PersistenceCoders.makeEncoder()
        encoder.outputFormatting.insert(.sortedKeys)
        return encoder
    }()

    init(directory: URL, maxRetiredRecords: Int, logCategory: String) {
        SecureFileWrite.ensureUserOnlyDirectory(directory)
        self.directory = directory
        self.maxRetiredRecords = max(0, maxRetiredRecords)
        self.log = Logger.limpid(logCategory)
    }

    func allRecords() -> [Record] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        var records: [Record] = []
        records.reserveCapacity(names.count)
        for name in names {
            guard name.hasSuffix(".state.json"), !name.hasPrefix(".") else { continue }
            let stem = String(name.dropLast(".state.json".count))
            guard UUID(uuidString: stem) != nil else { continue }
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(Record.self, from: data),
                  UUID(uuidString: record.paneId) != nil,
                  record.storageID == stem
            else { continue }
            records.append(record)
        }
        return records
    }

    /// Compatibility lookup for direct and schema-v1 callers. A pane can own
    /// several runtime records now, so the newest record wins deterministically.
    func record(forPaneID paneID: UUID) -> Record? {
        let pane = paneID.uuidString
        return allRecords()
            .filter { $0.paneId.caseInsensitiveCompare(pane) == .orderedSame }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func save(_ record: Record) throws {
        guard UUID(uuidString: record.storageID) != nil,
              UUID(uuidString: record.paneId) != nil
        else {
            throw NSError(
                domain: "dev.limpid.persistence.agent-state-store",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "invalid record id"]
            )
        }
        let url = fileURL(recordID: record.storageID)
        try SecureFileWrite.writeAtomic(encoder.encode(record), to: url)
    }

    /// Read-modify-write under the hook's kernel lock. We reload inside the
    /// critical section so a termination marker cannot overwrite a new hook.
    @discardableResult
    func update(
        recordID: String, matching: (Record) -> Bool = { _ in true }, transform: (inout Record) -> Void
    ) throws -> RecordMutationOutcome {
        guard UUID(uuidString: recordID) != nil else { return .preconditionChanged }
        let url = fileURL(recordID: recordID)
        return try AgentFileLock.withLock(for: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
            var latest = try decoder.decode(Record.self, from: Data(contentsOf: url))
            guard latest.storageID == recordID, matching(latest) else { return .preconditionChanged }
            transform(&latest)
            try save(latest)
            return .applied
        }
    }

    func delete(recordID: String) {
        guard let record = allRecords().first(where: { $0.storageID == recordID }) else { return }
        // Explicit pane closure is permitted to retire its direct runtime.
        // A concurrent newer hook wins; deletion never overwrites it.
        _ = try? removeIfUnchanged(record)
    }

    func removeIfUnchanged(_ record: Record) throws -> RecordMutationOutcome {
        let url = fileURL(recordID: record.storageID)
        return try AgentFileLock.withLock(for: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
            let latest = try decoder.decode(Record.self, from: Data(contentsOf: url))
            guard latest.storageID == record.storageID, latest.revision == record.revision,
                  latest.pid == record.pid, latest.updatedAt == record.updatedAt
            else { return .preconditionChanged }
            let retired = directory.appendingPathComponent("retired")
            SecureFileWrite.ensureUserOnlyDirectory(retired)
            let name = "\(record.storageID).\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString).state.json"
            try FileManager.default.moveItem(at: url, to: retired.appendingPathComponent(name))
            pruneRetired()
            return .applied
        }
    }

    /// Only retired metadata is count/age limited. Active and unresolved
    /// records are not evicted merely because the app has many agents.
    func pruneRetired(now: Date = Date()) {
        let retired = directory.appendingPathComponent("retired")
        guard let urls = try? FileManager.default.contentsOfDirectory(at: retired, includingPropertiesForKeys: nil) else { return }
        let entries = urls.compactMap { url -> (URL, TimeInterval)? in
            let fields = url.lastPathComponent.split(separator: ".")
            guard fields.count == 5, UUID(uuidString: String(fields[0])) != nil,
                  let stamp = TimeInterval(fields[1]), UUID(uuidString: String(fields[2])) != nil,
                  fields[3] == "state", fields[4] == "json",
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular
            else { return nil }
            return (url, stamp)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }
        for (index, entry) in entries.enumerated()
            where index >= maxRetiredRecords || now.timeIntervalSince1970 - entry.1 > AgentLifecyclePolicy.retiredLifetime
        {
            do {
                try FileManager.default.removeItem(at: entry.0)
            } catch {
                log.error("retired metadata cleanup failed: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    /// Nil means unavailable, not missing; transient read failure must not
    /// discard the accepted revision or a pending notification.
    func recordExists(recordID: String) -> Bool? {
        guard UUID(uuidString: recordID) != nil else { return false }
        do { _ = try FileManager.default.attributesOfItem(atPath: fileURL(recordID: recordID).path)
            return true
        } catch {
            let error = error as NSError
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError
            {
                return false
            }
            return nil
        }
    }

    func delete(paneID: UUID) {
        deleteRecords(launchedFrom: paneID, includingTmux: true)
    }

    func deleteRecords(launchedFrom paneID: UUID, includingTmux: Bool) {
        let pane = paneID.uuidString
        for record in allRecords()
            where record.paneId.caseInsensitiveCompare(pane) == .orderedSame
            && (includingTmux || !record.isTmuxRuntime)
        {
            delete(recordID: record.storageID)
        }
    }

    /// Compatibility entry point for explicit orphan removal. Count limits
    /// now belong exclusively to the retired metadata archive.
    func cleanup(removing recordIDs: Set<String>) {
        for id in recordIDs {
            delete(recordID: id)
        }
        pruneRetired()
    }

    private func fileURL(recordID: String) -> URL {
        directory.appendingPathComponent("\(recordID).state.json")
    }
}
