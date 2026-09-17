// TmuxServerSessions.swift
// Limpid — asks one socket, once, which sessions its server has, and where an agent's session keeps its pane.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.sessions")

/// One session of one server, as `TmuxServerSessions.listFormat` prints it.
/// Every row carries the server's own run, so any row answers for the
/// server (`TmuxServerGeneration`).
struct TmuxServerSessionRow: Equatable {
    let serverPID: String
    let serverStartedAt: String
    let sessionID: String
    let sessionName: String
}

/// What a socket said when we asked it about its sessions.
enum TmuxServerSessions: Equatable {
    /// The server answered. An empty list is an answer too: a server with
    /// `exit-empty off` holds no session any binding could name.
    case sessions([TmuxServerSessionRow])
    /// No server is on the socket (`TmuxSessionProbe.isServerAbsent`).
    case serverGone
    /// Nothing that says whether a server runs: it hangs, it refuses us for
    /// another reason, or the listing could not be read.
    case unreachable

    /// Session name and id are read beside the server run because a binding
    /// restored from disk may name either: an id when the server is the one
    /// it recorded, and a name when the user's own tmux was restored onto a
    /// new server (`TmuxReattachCommandBuilder`).
    static let listFormat = "#{pid}\t#{start_time}\t#{session_id}\t#{session_name}"

    static func classify(_ result: TmuxCommandResult, connectError: () -> Int32?) -> TmuxServerSessions {
        guard case let .success(output) = result else {
            return TmuxSessionProbe.isServerAbsent(after: result, connectError: connectError) ? .serverGone : .unreachable
        }
        var rows: [TmuxServerSessionRow] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            // A row we cannot read leaves us unable to say what the server
            // has, which is not the same as a server without the session.
            // Every binding on this socket then reads as unreachable, which
            // is otherwise indistinguishable from a server that hung.
            guard fields.count == 4 else {
                log.error("unreadable session row (\(fields.count, privacy: .public) fields): \(String(line), privacy: .private)")
                return .unreachable
            }
            rows.append(TmuxServerSessionRow(
                serverPID: String(fields[0]),
                serverStartedAt: String(fields[1]),
                sessionID: String(fields[2]),
                sessionName: String(fields[3])
            ))
        }
        return .sessions(rows)
    }

    /// Blocks on a child process; `check` runs it off the caller's thread.
    static func list(tmuxPath: String, socketPath: String) -> TmuxServerSessions {
        let result = TmuxCommand().run(
            executable: tmuxPath,
            arguments: TmuxCommand.clientArguments(socketPath: socketPath, ["list-sessions", "-F", listFormat])
        )
        return classify(result) { TmuxSessionProbe.connectError(socketPath: socketPath) }
    }

    /// A dispatch queue for the same reason as `TmuxSessionProbe.check`: the
    /// listing blocks on a child process, and forming the closure in a
    /// nonisolated function keeps main-actor isolation out of what Dispatch
    /// runs.
    nonisolated static func check(tmuxPath: String, socketPath: String) async -> TmuxServerSessions {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: list(tmuxPath: tmuxPath, socketPath: socketPath))
            }
        }
    }
}

/// The window and pane a mirror tab is opened on for a session that holds
/// one agent.
struct TmuxSessionPane: Equatable {
    /// `@N`
    let windowID: String
    /// `%N`
    let paneID: String
}

enum TmuxSessionPanes {
    static let listFormat = "#{window_id}\t#{pane_id}\t#{window_active}\t#{pane_active}"

    /// The session's active pane, in its active window. An agent's session
    /// has one window with one pane in it, so the choice only matters for a
    /// session the user split from inside; the mirror fills the window's
    /// other panes in from tmux's first layout report either way.
    static func active(in output: String) -> TmuxSessionPane? {
        var first: TmuxSessionPane?
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 4 else { continue }
            let pane = TmuxSessionPane(windowID: String(fields[0]), paneID: String(fields[1]))
            if fields[2] == "1", fields[3] == "1" {
                return pane
            }
            first = first ?? pane
        }
        return first
    }

    /// One listing for the whole session (`-s`), so a session costs one
    /// client however many windows it has. `nil` when the server did not
    /// answer or named no pane.
    static func list(tmuxPath: String, socketPath: String, sessionID: String) -> TmuxSessionPane? {
        let result = TmuxCommand().run(
            executable: tmuxPath,
            arguments: TmuxCommand.clientArguments(
                socketPath: socketPath,
                ["list-panes", "-s", "-t", sessionID, "-F", listFormat]
            )
        )
        guard case let .success(output) = result else { return nil }
        return active(in: output)
    }

    nonisolated static func check(tmuxPath: String, socketPath: String, sessionID: String) async -> TmuxSessionPane? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: list(tmuxPath: tmuxPath, socketPath: socketPath, sessionID: sessionID))
            }
        }
    }
}
