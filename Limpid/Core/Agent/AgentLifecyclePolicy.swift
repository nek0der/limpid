// AgentLifecyclePolicy.swift
// Limpid — explicit process evidence and conservative runtime retention.

import Foundation

enum AgentProcessStatus {
    case alive
    case dead
    case unknown

    static func inspect(_ rawPID: String?) -> AgentProcessStatus {
        guard let rawPID, let pid = pid_t(rawPID), pid > 1 else { return .unknown }
        if kill(pid, 0) == 0 {
            return .alive
        }
        if errno == EPERM {
            return .alive
        }
        return errno == ESRCH ? .dead : .unknown
    }
}

enum AgentLifecyclePolicy {
    static let retiredLifetime: TimeInterval = 7 * 24 * 60 * 60
    /// Bounds apply only to records eligible for removal, never live or
    /// unresolved runtime facts. Lack of a PID is not evidence of death.
    static func removableRecords(
        _ records: [some AgentLifecycleRecord], alivePanes: Set<UUID>, processStatus: (String?) -> AgentProcessStatus
    ) -> Set<String> {
        Set(records.compactMap { record in
            guard !record.isTmuxRuntime, let pane = UUID(uuidString: record.paneId), !alivePanes.contains(pane),
                  processStatus(record.pid) == .dead
            else { return nil }
            return record.storageID
        })
    }
}
