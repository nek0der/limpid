// AgentResumeIntentStore.swift
// Limpid — independent one-shot protection for direct agents killed at quit.

import Foundation

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
