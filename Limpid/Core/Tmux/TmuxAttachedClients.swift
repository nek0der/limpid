// TmuxAttachedClients.swift
// Limpid — the clients already attached to a session a mirror is about to open, and which of them to detach.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.mirror")

/// One client `list-clients` reports on a session.
struct TmuxAttachedClient: Equatable {
    /// What `detach-client -t` takes. tmux names a terminal client after
    /// its tty and a control client, which has none, `client-<pid>`.
    let name: String
    let pid: pid_t?
    let isControlMode: Bool
    let tty: String?
}

/// The clients a mirror deals with before it attaches (design D7). tmux
/// sizes a window from every client showing it, so a client left attached
/// can shrink the window the mirror draws.
struct TmuxAttachedClients: Equatable {
    /// Terminal clients running in one of Limpid's panes. Detaching one
    /// returns that pane to its shell with its scrollback intact, so it is
    /// done without asking.
    var limpidPanes: [TmuxAttachedClient] = []
    /// Everything this app did not start: a terminal elsewhere, or another
    /// app's control client. Detaching one closes what that app shows, so
    /// the user decides.
    var otherApps: [TmuxAttachedClient] = []

    /// Tab-separated with the tty last, the only field that can be empty.
    static let listFormat = "#{client_name}\t#{client_pid}\t#{client_control_mode}\t#{client_tty}"

    static func parse(_ output: String) -> [TmuxAttachedClient] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty, fields[2] == "0" || fields[2] == "1" else { return nil }
            return TmuxAttachedClient(
                name: String(fields[0]),
                pid: pid_t(fields[1]),
                isControlMode: fields[2] == "1",
                tty: fields[3].isEmpty ? nil : String(fields[3])
            )
        }
    }

    /// Sort `clients` for the mirror. `ownControlPIDs` are the control
    /// clients this app started; they are the mirrors' own connections and
    /// never in the way. `limpidTTYs` are the ttys of Limpid's panes.
    ///
    /// A control client is never taken for a Limpid pane: it has no tty,
    /// and one we did not start belongs to some other app.
    static func classify(
        _ clients: [TmuxAttachedClient],
        ownControlPIDs: Set<pid_t>,
        limpidTTYs: Set<String>
    ) -> TmuxAttachedClients {
        var result = TmuxAttachedClients()
        for client in clients {
            if client.isControlMode {
                if let pid = client.pid, ownControlPIDs.contains(pid) {
                    continue
                }
                result.otherApps.append(client)
            } else if let tty = client.tty, limpidTTYs.contains(tty) {
                result.limpidPanes.append(client)
            } else {
                result.otherApps.append(client)
            }
        }
        return result
    }

    /// The clients attached to `binding`'s session, or nil when tmux did
    /// not answer. The caller opens the mirror either way: a server that
    /// cannot list its clients will not take an attach either, and that
    /// failure is reported where the attach is made.
    static func probe(tmuxPath: String, binding: TmuxBinding) -> [TmuxAttachedClient]? {
        let result = TmuxCommand().run(
            executable: tmuxPath,
            arguments: TmuxCommand.clientArguments(
                socketPath: binding.socketPath,
                ["list-clients", "-t", binding.sessionID, "-F", listFormat]
            )
        )
        guard case let .success(output) = result else { return nil }
        return parse(output)
    }

    /// Detach each of `clients`. A client that left in the meantime makes
    /// tmux answer "can't find client", which is the state we wanted, so
    /// failures are only logged.
    static func detach(_ clients: [TmuxAttachedClient], tmuxPath: String, socketPath: String) {
        for client in clients {
            let result = TmuxCommand().run(
                executable: tmuxPath,
                arguments: TmuxCommand.clientArguments(socketPath: socketPath, ["detach-client", "-t", client.name])
            )
            if case .success = result {
                continue
            }
            log.notice("detach-client did not apply to \(client.name, privacy: .private): \(String(describing: result), privacy: .public)")
        }
    }
}
