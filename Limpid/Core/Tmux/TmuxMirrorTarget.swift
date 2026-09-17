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
    /// The server's own version, or nil when it left `#{version}` empty or
    /// reported something we cannot read. The palette gates on this, so a
    /// server we cannot place is shown as unavailable rather than guessed at.
    let serverVersion: TmuxVersion?

    var displayName: String {
        "\(binding.sessionName):\(windowName)"
    }

    /// tmux 3.3 added the per-window form of `refresh-client -C`
    /// (`@window:WxH`), which a mirror sends to size the window to its tab.
    /// An older server rejects that form, so its windows are listed but
    /// cannot be opened.
    static let minimumVersion = TmuxVersion(major: 3, minor: 3, patch: nil, isDevelopment: false)

    /// False for an unknown version as well as an old one: a server we
    /// cannot place is not assumed to be new enough.
    var isSupported: Bool {
        serverVersion.map { $0 >= Self.minimumVersion } ?? false
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

    /// Tab-separated because names may contain spaces. The ids and server
    /// fields come first and the window name last, so a tab inside a window
    /// name survives as the remainder of the line; a tab inside a session
    /// name does not.
    ///
    /// `version`, `pid`, and `start_time` are server-wide. tmux expands a
    /// variable it does not know to an empty string, so a server too old to
    /// have one still lists its windows with that field empty.
    static let listFormat = [
        "#{session_id}", "#{window_id}", "#{pane_id}",
        "#{version}", "#{pid}", "#{start_time}",
        "#{session_name}", "#{window_name}"
    ].joined(separator: "\t")

    static func parse(_ output: String, socketPath: String) -> [TmuxMirrorTarget] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 7, omittingEmptySubsequences: false)
            guard fields.count == 8, fields[0].hasPrefix("$"), fields[1].hasPrefix("@"), fields[2].hasPrefix("%") else {
                return nil
            }
            var binding = TmuxBinding(socketPath: socketPath, sessionID: String(fields[0]), sessionName: String(fields[6]))
            // Recorded only as a pair of numbers: the reattach condition
            // splices both into a tmux format, and half a generation
            // authenticates nothing.
            if UInt64(fields[4]) != nil, UInt64(fields[5]) != nil {
                binding.serverPID = String(fields[4])
                binding.serverStartedAt = String(fields[5])
            }
            return TmuxMirrorTarget(
                binding: binding,
                windowID: String(fields[1]),
                windowName: String(fields[7]),
                activePaneID: String(fields[2]),
                serverVersion: TmuxProtocol.parseVersion(String(fields[3]))
            )
        }
    }
}
