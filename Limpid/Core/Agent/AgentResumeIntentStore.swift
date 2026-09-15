// AgentResumeIntentStore.swift
// Limpid — independent one-shot protection for direct agents killed at quit.

import Foundation
import OSLog

private let log = Logger.limpid("agent.resume.intents")

struct AgentResumeIntent: Codable {
    let runID: String
    let paneID: UUID
    let sessionID: String
    let ownerRunID: String?
    let pid: String
    let createdAt: Date
}

final class AgentResumeIntentStore {
    static let lifetime: TimeInterval = 24 * 60 * 60
    let directory: URL

    init(directory: URL) {
        self.directory = directory
        SecureFileWrite.ensureUserOnlyDirectory(directory)
    }

    func save(_ intent: AgentResumeIntent) throws {
        guard UUID(uuidString: intent.runID) != nil else { throw POSIXError(.EINVAL) }
        try SecureFileWrite.writeAtomic(PersistenceCoders.makeEncoder().encode(intent), to: url(intent.runID))
    }

    func record(runID: String) -> AgentResumeIntent? {
        guard UUID(uuidString: runID) != nil else { return nil }
        // Absence or an unreadable intent supplies no authority for cleanup.
        guard let data = try? Data(contentsOf: url(runID)) else { return nil }
        return try? PersistenceCoders.makeDecoder().decode(AgentResumeIntent.self, from: data)
    }

    /// Every intent currently on disk.
    ///
    /// The rules need the whole set, not one lookup: an intent is what says a
    /// run was killed by Limpid rather than lost, and a run whose intent is
    /// not in the input is retired as an orphan.
    func allIntents() -> [AgentResumeIntent] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                return nil
            }
            return try? PersistenceCoders.makeDecoder().decode(AgentResumeIntent.self, from: data)
        }
    }

    /// Takes over the intents an earlier build left under `legacy`.
    ///
    /// Intents used to live under each provider's state directory, but an
    /// intent is not provider-scoped — it names a run, a pane and a pid — so
    /// they moved to one shared directory. Without this, the first launch
    /// after the move would find no intent for any run Limpid killed at the
    /// previous quit and retire every one of them as an orphan, which is the
    /// restore the user was promised silently not happening.
    ///
    /// An intent already present here wins: it was written by this build, so
    /// it describes the run more recently than the file left behind. Failures
    /// are logged rather than thrown, because a migration that cannot run
    /// costs a restore, and refusing to launch costs more.
    func adoptLegacyIntents(from legacy: URL) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: legacy.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let target = directory.appendingPathComponent(name)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.moveItem(at: legacy.appendingPathComponent(name), to: target)
            } catch {
                log.error("adopt intent \(name, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        // Only when nothing is left: anything we could not move is still
        // someone's evidence, and a later launch can try again.
        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacy.path), remaining.isEmpty {
            try? fileManager.removeItem(at: legacy)
        }
    }

    func remove(runID: String) throws {
        guard UUID(uuidString: runID) != nil else { return }
        let target = url(runID)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
    }

    private func url(_ runID: String) -> URL {
        directory.appendingPathComponent(runID + ".json")
    }
}
