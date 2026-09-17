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
    /// The number tmux shows the window by in its status line. Only read to
    /// tell apart windows that share a name; `nil` where the target was not
    /// listed (a window `break-pane` made, a tab being reconnected).
    var windowIndex: Int?

    var displayName: String {
        Self.displayName(sessionName: binding.sessionName, windowName: windowName)
    }

    /// `session:window`, the name a palette row and a mirror tab carry.
    static func displayName(sessionName: String, windowName: String) -> String {
        "\(sessionName):\(windowName)"
    }

    /// The window name inside a mirror tab's stored title, which is
    /// `displayName` once tmux has named the window. A title that does not
    /// start with the session's name (one saved by a build whose tab
    /// followed the pane's terminal title) is taken whole; the mirror asks
    /// tmux for the real name as soon as it connects.
    static func windowName(inTitle title: String, sessionName: String) -> String {
        let prefix = "\(sessionName):"
        guard title.hasPrefix(prefix) else { return title }
        return String(title.dropFirst(prefix.count))
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
                arguments: TmuxCommand.clientArguments(socketPath: path, ["list-windows", "-a", "-F", listFormat])
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
        "#{version}", "#{pid}", "#{start_time}", "#{window_index}",
        "#{session_name}", "#{window_name}"
    ].joined(separator: "\t")

    static func parse(_ output: String, socketPath: String) -> [TmuxMirrorTarget] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9, fields[0].hasPrefix("$"), fields[1].hasPrefix("@"), fields[2].hasPrefix("%") else {
                return nil
            }
            var binding = TmuxBinding(socketPath: socketPath, sessionID: String(fields[0]), sessionName: String(fields[7]))
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
                windowName: String(fields[8]),
                activePaneID: String(fields[2]),
                serverVersion: TmuxProtocol.parseVersion(String(fields[3])),
                windowIndex: Int(fields[6])
            )
        }
    }
}

extension TmuxMirrorTarget {
    /// What tells each target apart from the others listed under the same
    /// `displayName`, in the order given; `nil` for a target whose name is
    /// unique. Two servers are told apart by their socket's name (the
    /// `-L` name, or the whole path when two sockets share a file name),
    /// two windows of one session by the number tmux shows them by, so the
    /// row reads the way the user finds the window in tmux. Only what
    /// differs within the group is shown.
    static func distinguishingLabels(for targets: [TmuxMirrorTarget]) -> [String?] {
        let groups = Dictionary(grouping: targets.indices) { targets[$0].displayName }
        var labels = [String?](repeating: nil, count: targets.count)
        for indices in groups.values where indices.count > 1 {
            let sockets = Set(indices.map { targets[$0].binding.socketPath })
            let socketNames = Dictionary(grouping: sockets) { URL(fileURLWithPath: $0).lastPathComponent }
            for index in indices {
                let target = targets[index]
                var parts: [String] = []
                if sockets.count > 1 {
                    let path = target.binding.socketPath
                    let name = URL(fileURLWithPath: path).lastPathComponent
                    let server = socketNames[name, default: []].count > 1 ? (path as NSString).abbreviatingWithTildeInPath : name
                    parts.append(String(localized: "Server \(server)", comment: "tmux palette row — which server a window is on"))
                }
                let isNameSharedOnServer = indices.contains { other in
                    other != index && targets[other].binding.socketPath == target.binding.socketPath
                }
                if isNameSharedOnServer {
                    parts.append(target.windowIndex.map {
                        String(localized: "Window \($0)", comment: "tmux palette row — the window's number in tmux")
                    } ?? target.windowID)
                }
                labels[index] = parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        }
        return labels
    }
}
