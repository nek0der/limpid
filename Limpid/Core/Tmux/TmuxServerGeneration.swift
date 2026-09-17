// TmuxServerGeneration.swift
// Limpid — tells whether the tmux server on a socket is the one a binding recorded, before a mirror attaches to it.

import Foundation

/// A socket path outlives its server: a restarted server listens on the
/// same path and numbers its sessions and windows from zero again, so a
/// session id alone could attach a tab to someone else's session. A
/// binding records the server's pid and start time, and the two together
/// name one server run.
enum TmuxServerGeneration {
    /// The server run a binding recorded.
    struct Recorded: Equatable {
        let pid: String
        let startedAt: String
    }

    enum Verdict: Equatable {
        /// The server is the recorded one. `hasSession` says whether it
        /// still lists the binding's session.
        case matches(hasSession: Bool)
        /// Another server answers on the socket.
        case replaced
        /// The binding does not say which server it was showing, so no
        /// answer could tell. Nothing is asked of tmux.
        case unrecorded
        /// No server is on the socket (`TmuxSessionProbe.isServerAbsent`),
        /// so none of its sessions exists any more.
        case serverGone
        /// No answer that says whether a server runs: the server hangs, the
        /// socket refuses us for another reason, the listing cannot be
        /// read, or tmux could not be run.
        case unreachable
    }

    /// One row per session. Every row carries the server's own pid and
    /// start time, so any row answers for the server.
    static let listFormat = "#{pid}\t#{start_time}\t#{session_id}"

    /// The generation `binding` recorded, or `nil` when it has none. A
    /// binding restored from an agent record carries empty strings where
    /// the record had no values.
    static func recorded(in binding: TmuxBinding) -> Recorded? {
        guard let pid = binding.serverPID, let startedAt = binding.serverStartedAt,
              !pid.isEmpty, !startedAt.isEmpty
        else { return nil }
        return Recorded(pid: pid, startedAt: startedAt)
    }

    /// Blocks on a child process; `check` runs it off the caller's thread.
    static func verdict(tmuxPath: String, binding: TmuxBinding) -> Verdict {
        guard let recorded = recorded(in: binding) else { return .unrecorded }
        let result = TmuxCommand().run(
            executable: tmuxPath,
            arguments: TmuxCommand.clientArguments(socketPath: binding.socketPath, ["list-sessions", "-F", listFormat])
        )
        return classify(result, recorded: recorded, sessionID: binding.sessionID) {
            TmuxSessionProbe.connectError(socketPath: binding.socketPath)
        }
    }

    /// A client that failed is split the way the session check after a
    /// connection ended splits it, so a stopped server ends the tabs on
    /// either path.
    ///
    /// A server that answers with no sessions at all (`exit-empty off`)
    /// states no generation. It cannot hold the binding's session either
    /// way, and it is taken as replaced so the tab keeps what it showed
    /// rather than being closed as a session that ended.
    static func classify(
        _ result: TmuxCommandResult,
        recorded: Recorded,
        sessionID: String,
        connectError: () -> Int32?
    ) -> Verdict {
        guard case let .success(output) = result else {
            return TmuxSessionProbe.isServerAbsent(after: result, connectError: connectError) ? .serverGone : .unreachable
        }
        var server: Recorded?
        var hasSession = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3 else { return .unreachable }
            server = server ?? Recorded(pid: String(fields[0]), startedAt: String(fields[1]))
            hasSession = hasSession || fields[2] == sessionID
        }
        guard server == recorded else { return .replaced }
        return .matches(hasSession: hasSession)
    }

    /// A dispatch queue for the same reason as `TmuxSessionProbe.check`:
    /// the listing blocks on a child process, and this nonisolated function
    /// keeps main-actor isolation out of the closure Dispatch runs.
    nonisolated static func check(tmuxPath: String, binding: TmuxBinding) async -> Verdict {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: verdict(tmuxPath: tmuxPath, binding: binding))
            }
        }
    }
}
