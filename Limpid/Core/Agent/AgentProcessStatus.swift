// AgentProcessStatus.swift
// Limpid — what this process can tell about another one still being there.

import Foundation

/// Evidence about an agent process, as `kill(pid, 0)` reports it.
///
/// Three cases rather than a `Bool` because "we could not tell" is a distinct
/// answer from "it is gone": the rules retire a runtime only on `.dead`, so a
/// missing or unparsable pid, or a kernel answer we do not recognize, leaves
/// the record alone instead of discarding a live agent's state.
enum AgentProcessStatus {
    case alive
    case dead
    case unknown

    static func inspect(_ rawPID: String?) -> AgentProcessStatus {
        guard let rawPID, let pid = pid_t(rawPID), pid > 1 else { return .unknown }
        if kill(pid, 0) == 0 {
            return .alive
        }
        // A process we are not allowed to signal is still a process.
        if errno == EPERM {
            return .alive
        }
        return errno == ESRCH ? .dead : .unknown
    }
}
