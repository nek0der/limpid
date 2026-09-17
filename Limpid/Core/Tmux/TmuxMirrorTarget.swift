// TmuxMirrorTarget.swift
// Limpid — the tmux windows a user can mirror, listed from every server socket we can see.

import Foundation

/// One window of one session on one server: what the palette offers and
/// what a mirror tab is opened on. `activePaneID` seeds the tab's first
/// leaf; the first `%layout-change` then fills in the rest.
struct TmuxMirrorTarget: Equatable {
    let binding: TmuxBinding
    let windowID: String
    let windowName: String
    let activePaneID: String

    var displayName: String {
        "\(binding.sessionName):\(windowName)"
    }
}

enum TmuxMirrorTargetLister {
    /// `list-windows -a` across the sockets in tmux's server directory.
    /// One short-lived client per socket, bounded by `TmuxCommand`'s
    /// timeout, so a dead socket costs a few milliseconds and nothing more.
    ///
    /// Limpid's own agent servers are skipped: each of their sessions is
    /// already on screen as the pane that started the agent, and opening
    /// it again as a tab would show the same agent twice.
    static func targets(
        tmuxPath: String,
        socketPaths: [URL] = TmuxClientProbe.socketPaths(inServerDirectory: TmuxClientProbe.defaultServerDirectory())
    ) -> [TmuxMirrorTarget] {
        var targets: [TmuxMirrorTarget] = []
        for socket in socketPaths where !PaneShellEnvironment.isAgentSocketName(socket.lastPathComponent) {
            let path = TmuxClientProbe.normalizeSocketPath(socket.path)
            let result = TmuxCommand().run(
                executable: tmuxPath,
                arguments: ["-S", path, "list-windows", "-a", "-F", listFormat]
            )
            guard case let .success(output) = result else { continue }
            targets.append(contentsOf: parse(output, socketPath: path))
        }
        return targets
    }

    /// Tab-separated because names may contain spaces. The ids come first
    /// and the window name last, so a tab inside a window name survives
    /// as the remainder of the line; a tab inside a session name does not.
    static let listFormat = "#{session_id}\t#{window_id}\t#{pane_id}\t#{session_name}\t#{window_name}"

    static func parse(_ output: String, socketPath: String) -> [TmuxMirrorTarget] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, fields[0].hasPrefix("$"), fields[1].hasPrefix("@"), fields[2].hasPrefix("%") else {
                return nil
            }
            return TmuxMirrorTarget(
                binding: TmuxBinding(socketPath: socketPath, sessionID: String(fields[0]), sessionName: String(fields[3])),
                windowID: String(fields[1]),
                windowName: String(fields[4]),
                activePaneID: String(fields[2])
            )
        }
    }
}
