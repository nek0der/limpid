// AgentCommandExecutor.swift
// Limpid — applies the file changes the Rust rules asked for, under the lock.

import Foundation
import OSLog

private let log = Logger.limpid("agent.command.executor")

/// The directories one provider keeps its state in, as its descriptor declares
/// them.
struct AgentDirectories {
    var state: URL
    var sessions: URL
    var cwdEvents: URL?

    var retired: URL {
        state.appendingPathComponent("retired", isDirectory: true)
    }
}

/// Runs the file commands a projection pass returned.
///
/// The rules reasoned about a snapshot; by the time this runs a hook may have
/// written again. So every command names the precondition to recheck, and this
/// is the one place that takes the lock, rechecks it, and decides whether the
/// rest of the chain still applies. Spreading that across call sites would
/// leave the same compare-and-set logic in several places.
///
/// Records are handled as the JSON they are rather than decoded into a type.
/// The writer owns their shape; this side only applies named field changes and
/// compares named fields, so a record gaining a field needs no change here.
@MainActor
struct AgentCommandExecutor {
    /// Per provider, plus the shared directory resume intents live in.
    let directories: [String: AgentDirectories]
    let resumeIntents: AgentResumeIntentStore

    /// Applies every command in order and reports what happened. Commands that
    /// address no file are left for the caller, which owns the interface.
    @discardableResult
    func run(_ commands: [AgentProjectionCommand]) -> [AgentCommandOutcome] {
        var outcomes: [AgentCommandOutcome] = []
        for command in commands {
            apply(command, into: &outcomes)
        }
        return outcomes
    }

    private func apply(_ command: AgentProjectionCommand, into outcomes: inout [AgentCommandOutcome]) {
        guard let url = fileURL(for: command.target) else {
            // Either the target needs no lock, or it names a provider this
            // build does not have. Neither is this executor's to perform.
            return
        }
        let result: RecordMutationOutcome
        if needsLock(command.target) {
            do {
                result = try AgentFileLock.withLock(for: url) { perform(command, at: url) }
            } catch {
                log.error("command failed: \(error.localizedDescription, privacy: .private)")
                outcomes.append(.mismatched(command.target))
                return
            }
        } else {
            result = perform(command, at: url)
        }

        switch result {
        case .applied:
            outcomes.append(.applied(command.target))
            for next in command.then {
                apply(next, into: &outcomes)
            }
        case .notFound, .preconditionChanged:
            outcomes.append(.mismatched(command.target))
            // The mismatch is a fact about this target, not necessarily a
            // reason to abandon the rest: a hint that belongs to a newer run
            // should stay while the dead record it accompanied still goes.
            if command.onMismatch == .continue {
                for next in command.then {
                    apply(next, into: &outcomes)
                }
            }
        case .busy:
            // Somebody is mid-write, so the snapshot this was decided from is
            // already stale. Stop the chain whatever it asked for and let the
            // next pass decide again.
            outcomes.append(.busy(command.target))
        }
    }

    // MARK: - Operations

    private func perform(_ command: AgentProjectionCommand, at url: URL) -> RecordMutationOutcome {
        switch command.op {
        case .retire:
            retire(url, expect: command.expect, target: command.target)
        case let .update(patch):
            update(url, patch: patch, expect: command.expect)
        case .delete:
            delete(url, expect: command.expect)
        case let .writeResumeIntent(intent):
            write(intent)
        case let .pruneRetired(max, lifetime):
            pruneRetired(command.target, max: max, lifetimeSeconds: lifetime)
        case let .cleanupPaneStore(keep, max):
            cleanupPaneStore(command.target, keep: keep, max: max)
        case .notify, .markViewed, .cwdChanged, .gitSyncRefetch, .unknown:
            .applied
        }
    }

    /// Moves a record aside rather than deleting it. A record that turns out
    /// to have been live is still there to be read.
    private func retire(
        _ url: URL,
        expect: AgentCommandPrecondition,
        target: AgentCommandTarget
    ) -> RecordMutationOutcome {
        guard let record = readJSON(url) else { return .notFound }
        guard matches(expect, record: record) else { return .preconditionChanged }
        guard case let .record(provider, storageID) = target,
              let owner = directories[provider]
        else {
            return .preconditionChanged
        }
        SecureFileWrite.ensureUserOnlyDirectory(owner.retired)
        let name = "\(storageID).\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString).state.json"
        do {
            try FileManager.default.moveItem(
                at: url,
                to: owner.retired.appendingPathComponent(name)
            )
        } catch {
            log.error("retire failed: \(error.localizedDescription, privacy: .private)")
            return .preconditionChanged
        }
        return .applied
    }

    private func update(
        _ url: URL,
        patch: AgentRecordPatch,
        expect: AgentCommandPrecondition
    ) -> RecordMutationOutcome {
        guard var record = readJSON(url) else { return .notFound }
        guard matches(expect, record: record) else { return .preconditionChanged }
        apply(patch.state, to: &record, key: "state")
        apply(patch.pid, to: &record, key: "pid")
        apply(patch.killedByLimpidAt, to: &record, key: "killedByLimpidAt")
        apply(patch.resumeAttemptedAt, to: &record, key: "resumeAttemptedAt")
        return writeJSON(record, to: url)
    }

    private func apply(
        _ field: AgentPatchField<String>,
        to record: inout [String: Any],
        key: String
    ) {
        switch field {
        case .keep: break
        case .clear: record.removeValue(forKey: key)
        case let .set(value): record[key] = value
        }
    }

    private func delete(_ url: URL, expect: AgentCommandPrecondition) -> RecordMutationOutcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
        if case let .hintOwner(runID) = expect {
            guard let hint = readJSON(url) else { return .notFound }
            guard hint["runId"] as? String == runID else { return .preconditionChanged }
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            log.error("delete failed: \(error.localizedDescription, privacy: .private)")
            return .preconditionChanged
        }
        return .applied
    }

    private func write(_ intent: AgentResumeIntentPayload) -> RecordMutationOutcome {
        do {
            try resumeIntents.save(AgentResumeIntent(
                runID: intent.runID,
                paneID: intent.paneID,
                sessionID: intent.sessionID,
                ownerRunID: intent.ownerRunID,
                pid: intent.pid,
                createdAt: AgentDateParsing.parseISO8601(intent.createdAt) ?? Date()
            ))
        } catch {
            log.error("resume intent failed: \(error.localizedDescription, privacy: .private)")
            return .preconditionChanged
        }
        return .applied
    }

    /// Only the retired directory is bounded here. Live state records are
    /// never evicted just because the machine has run a lot of agents.
    private func pruneRetired(
        _ target: AgentCommandTarget,
        max: Int,
        lifetimeSeconds: Int
    ) -> RecordMutationOutcome {
        guard case let .retiredRecords(provider) = target,
              let retired = directories[provider]?.retired,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: retired,
                  includingPropertiesForKeys: nil
              )
        else {
            return .applied
        }
        let entries = urls.compactMap { url -> (URL, TimeInterval)? in
            // The name is the only thing that says when a record was retired,
            // so anything that does not parse is left where it is.
            let fields = url.lastPathComponent.split(separator: ".")
            guard fields.count == 5, UUID(uuidString: String(fields[0])) != nil,
                  let stamp = TimeInterval(fields[1]), UUID(uuidString: String(fields[2])) != nil,
                  fields[3] == "state", fields[4] == "json"
            else { return nil }
            return (url, stamp)
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }

        let now = Date().timeIntervalSince1970
        for (index, entry) in entries.enumerated()
            where index >= max || now - entry.1 > TimeInterval(lifetimeSeconds)
        {
            try? FileManager.default.removeItem(at: entry.0)
        }
        return .applied
    }

    private func cleanupPaneStore(
        _ target: AgentCommandTarget,
        keep: Set<UUID>,
        max: Int
    ) -> RecordMutationOutcome {
        guard case let .paneStore(provider, store) = target,
              let directory = paneStoreURL(provider: provider, store: store),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              )
        else {
            return .applied
        }
        var survivors: [(URL, Date)] = []
        // Files a writer is holding. Kept apart so the cap below cannot undo
        // the wait, and counted so the deferral is visible in a log.
        var busy: [URL] = []
        for url in urls where url.pathExtension == "json" {
            let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
            if let pane = UUID(uuidString: stem), keep.contains(pane) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                survivors.append((url, modified))
                continue
            }
            // A hook may be mid-write on this pane's file. The sweep is not
            // urgent — the pane is gone either way — so a held lock defers it
            // to the next pass rather than destroying a write in progress.
            let removal = try? AgentFileLock.withLock(for: url) {
                do {
                    try FileManager.default.removeItem(at: url)
                    return .applied
                } catch {
                    return .notFound
                }
            }
            if removal == .busy {
                busy.append(url)
            }
        }
        // The cap is a backstop for a directory that has grown without a pane
        // ever closing; the newest are the ones worth keeping. Files a writer
        // is holding are left out of it entirely: dropping one here would undo
        // the wait above for the sake of a bound that is not urgent.
        for (url, _) in survivors.sorted(by: { $0.1 > $1.1 }).dropFirst(max) {
            try? FileManager.default.removeItem(at: url)
        }
        if !busy.isEmpty {
            log.debug("pane store sweep deferred \(busy.count, privacy: .public) locked files")
        }
        return .applied
    }

    /// Whether the target is a single file another writer could be holding.
    ///
    /// A sweep addresses a whole directory, and only this process sweeps, so
    /// locking one would protect nothing — and the lock file would land beside
    /// the user's data directories rather than inside them.
    ///
    /// Worktree events are the exception among single files: the hook writes
    /// them by renaming a temporary into place and never takes the lock, so
    /// there is no other holder to wait for. Taking it anyway would leave a
    /// lock file in the same directory we scan for events, and the next pass
    /// would read that file as an event of its own.
    private func needsLock(_ target: AgentCommandTarget) -> Bool {
        switch target {
        case .retiredRecords, .paneStore, .host, .unknown, .worktreeEvent: false
        case .record, .sessionHint, .resumeIntent: true
        }
    }

    // MARK: - Addressing

    private func fileURL(for target: AgentCommandTarget) -> URL? {
        switch target {
        case let .record(provider, storageID):
            isIdentifier(storageID)
                ? directories[provider]?.state.appendingPathComponent("\(storageID).state.json")
                : nil
        case let .sessionHint(provider, pane):
            directories[provider]?.sessions
                .appendingPathComponent("\(pane.uuidString).json")
        case let .resumeIntent(runID):
            isIdentifier(runID)
                ? resumeIntents.directory.appendingPathComponent("\(runID).json")
                : nil
        case let .worktreeEvent(provider, fileName):
            isFileName(fileName)
                ? directories[provider]?.state
                .appendingPathComponent("worktree-events", isDirectory: true)
                .appendingPathComponent(fileName)
                : nil
        case let .retiredRecords(provider):
            directories[provider]?.retired
        case let .paneStore(provider, store):
            paneStoreURL(provider: provider, store: store)
        case .host, .unknown:
            nil
        }
    }

    /// Whether a name the rules sent is one we will build a path from.
    ///
    /// Everything the rules name came from a directory entry, so neither of
    /// these can currently fail. They are here because the check is what keeps
    /// a future rule — or a record whose own fields were tampered with — from
    /// addressing a file outside the directory it was found in.
    private func isIdentifier(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func isFileName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
    }

    private func paneStoreURL(provider: String, store: AgentPaneStoreKind) -> URL? {
        switch store {
        case .sessions: directories[provider]?.sessions
        case .cwdEvents: directories[provider]?.cwdEvents
        }
    }

    // MARK: - Preconditions

    private func matches(
        _ expect: AgentCommandPrecondition,
        record: [String: Any]
    ) -> Bool {
        switch expect {
        case .none, .exists:
            true
        case let .recordUnchanged(storageID, revision, pid, updatedAt):
            self.storageID(of: record) == storageID
                && record["revision"] as? Int == revision
                && record["pid"] as? String == pid
                && record["updatedAt"] as? String == updatedAt
        case let .pidAndRevision(pid, revision):
            record["pid"] as? String == pid
                && record["revision"] as? Int == revision
        case let .hintOwner(runID):
            record["runId"] as? String == runID
        case .unknown:
            // A precondition this build cannot check is not one it may assume.
            false
        }
    }

    /// The record's file name: its run id when it has one, and its pane id
    /// otherwise. Matches how the writer names the file.
    private func storageID(of record: [String: Any]) -> String? {
        if let runID = record["runId"] as? String, UUID(uuidString: runID) != nil {
            return runID.uppercased()
        }
        return (record["paneId"] as? String)?.uppercased()
    }

    // MARK: - JSON

    private func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func writeJSON(_ record: [String: Any], to url: URL) -> RecordMutationOutcome {
        do {
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("write failed: \(error.localizedDescription, privacy: .private)")
            return .preconditionChanged
        }
        return .applied
    }
}
