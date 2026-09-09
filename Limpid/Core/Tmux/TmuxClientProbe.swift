// TmuxClientProbe.swift
// Limpid — reads which tmux session is driving a pane.
//
// tmux knows, per attached client, the tty it is writing to, and
// libghostty tells us a surface's tty. Matching the two identifies the
// session a pane is showing however the user got there — a session they
// created here, or one they attached to from somewhere else.
//
// Asking tmux beats asking the shell. A shell inside tmux carries the
// `LIMPID_PANE_ID` of whichever pane created that session, frozen at
// creation, so a session reattached from a second pane would keep
// reporting the first one. The tty always names the pane in front of
// the user right now.

import Foundation

enum TmuxClientProbe {
    /// The string adapter keeps existing persistence and command APIs intact.
    /// Identity comparisons use `TmuxSocketPath` rather than URL formatting.
    static func normalizeSocketPath(_ path: String) -> String {
        TmuxSocketPath(path)?.value ?? path
    }

    /// Tab-separated because a session name may contain spaces, which
    /// tmux permits. Only the first two fields are structural.
    static let listClientsArguments = [
        "list-clients", "-F", "#{client_tty}\t#{session_id}\t#{session_name}"
    ]

    /// What the kernel reports as the name of a tmux client process. It
    /// truncates to `MAXCOMLEN`, which this is well inside, and it is already a
    /// basename so an install path never reaches the comparison.
    ///
    /// Here rather than on `TmuxPanePresence`: the review probe compares
    /// against it too, and that type is `@MainActor` with the whole surface
    /// registry behind it.
    static let clientProcessName = "tmux"

    /// Parse `list-clients` output into bindings keyed by client tty.
    ///
    /// A malformed line is skipped rather than failing the batch: the
    /// worst case is one pane that does not reattach, and refusing the
    /// whole answer would cost the others for no gain.
    static func parseClients(_ output: String, socketPath: String) -> [String: TmuxBinding] {
        var bindings: [String: TmuxBinding] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, !fields[0].isEmpty else { continue }
            bindings[String(fields[0])] = TmuxBinding(
                socketPath: socketPath,
                sessionID: String(fields[1]),
                sessionName: String(fields[2])
            )
        }
        return bindings
    }

    /// Where package managers put tmux. Resolving by name is not an
    /// option: a GUI app launched from Finder or the Dock inherits
    /// launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), which
    /// contains no Homebrew — the same reason `ToolLocator` exists.
    static let tmuxCandidates = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux"
    ]

    /// Absolute path of an installed tmux, or `nil`. Synchronous
    /// because the caller runs at termination, where `ToolLocator`'s
    /// actor cannot be awaited.
    static func locateTmux(candidates: [String] = tmuxCandidates) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Every client attached to any server under `serverDirectory`,
    /// keyed by the tty it is driving.
    ///
    /// Synchronous, because the one caller runs inside
    /// `applicationWillTerminate` where there is nothing to await on.
    /// The cost is bounded twice over: the directory scan short-circuits
    /// for the common case of a user with no tmux at all, and each
    /// server gets `timeout` before we give up on it and move on. A
    /// server we cannot reach in time simply contributes no bindings.
    static func attachedClients(
        tmuxPath: String,
        serverDirectory: URL,
        timeout: TimeInterval = 0.5
    ) -> [String: TmuxBinding] {
        attachedClients(
            tmuxPath: tmuxPath,
            socketPaths: socketPaths(inServerDirectory: serverDirectory),
            timeout: timeout
        )
    }

    static func attachedClients(
        tmuxPath: String,
        socketPaths: [URL],
        timeout: TimeInterval = 0.5
    ) -> [String: TmuxBinding] {
        var clients: [String: TmuxBinding] = [:]
        for socket in socketPaths {
            let path = normalizeSocketPath(socket.path)
            guard let output = runTmux(
                tmuxPath: tmuxPath,
                socketPath: path,
                arguments: listClientsArguments,
                timeout: timeout
            ) else { continue }
            // Later servers win a tty collision, which cannot happen:
            // one tty drives at most one client.
            clients.merge(parseClients(output, socketPath: path)) { _, new in new }
        }
        return clients
    }

    static func topology(tmuxPath: String, socketPaths: [URL], timeout: TimeInterval = 0.5) -> TmuxTopology {
        probe(tmuxPath: tmuxPath, paths: Set(socketPaths.map(\.path)), timeout: timeout).snapshot
    }

    struct ProbeBatch {
        var snapshot: TmuxTopology
        var nextCursor: Int
    }

    static func probe(
        tmuxPath: String, paths: Set<String>, cursor: Int = 0,
        timeout: TimeInterval = TmuxTiming.queryTimeout
    ) -> ProbeBatch {
        var snapshot = TmuxTopology()
        for raw in paths {
            guard let key = TmuxSocketPath(raw) else { continue }
            snapshot.socketAliases[raw] = key.value
            snapshot.socketAliases[key.value] = key.value
        }
        let ordered = Set(snapshot.socketAliases.values).sorted()
        guard !ordered.isEmpty else { return ProbeBatch(snapshot: snapshot, nextCursor: 0) }
        let deadline = ProcessInfo.processInfo.systemUptime + TmuxTiming.pollBudget
        var visited = 0
        for offset in ordered.indices {
            guard deadline - ProcessInfo.processInfo.systemUptime > TmuxTiming.terminationGrace + TmuxTiming.drainGrace else { break }
            let path = ordered[(cursor + offset) % ordered.count]
            visited += 1
            snapshot.observedAt[path] = ProcessInfo.processInfo.systemUptime
            var info = stat()
            guard lstat(path, &info) == 0, info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) == S_IFSOCK
            else { snapshot.outcomes[path] = .launchFailed
                continue
            }
            let result = probeServer(tmuxPath: tmuxPath, socketPath: path, deadline: deadline, timeout: timeout)
            snapshot.outcomes[path] = result.outcome
            snapshot.panes += result.panes
            snapshot.clients.merge(result.clients) { _, new in new }
        }
        return ProbeBatch(snapshot: snapshot, nextCursor: (cursor + visited) % ordered.count)
    }

    private struct ServerResult {
        let outcome: TmuxCommandResult
        var panes: [TmuxPaneLocation] = []
        var clients: [String: TmuxBinding] = [:]
    }

    private static func probeServer(
        tmuxPath: String, socketPath: String, deadline: TimeInterval, timeout: TimeInterval
    ) -> ServerResult {
        func query(_ arguments: [String]) -> TmuxCommandResult {
            let available = deadline - ProcessInfo.processInfo.systemUptime - TmuxTiming.terminationGrace - TmuxTiming.drainGrace
            guard available > 0 else { return .timedOut }
            return TmuxCommand().run(executable: tmuxPath, arguments: ["-S", socketPath] + arguments, timeout: min(timeout, available))
        }
        let paneResult = query(TmuxTopology.paneArguments)
        guard case let .success(paneText) = paneResult else { return ServerResult(outcome: paneResult) }
        let panes = TmuxTopology.parsePanes(paneText, socketPath: socketPath)
        guard !panes.isEmpty, panes.count == paneText.split(separator: "\n").count else { return ServerResult(outcome: .invalidOutput) }
        let clientResult = query(listClientsArguments)
        guard case let .success(clientText) = clientResult else { return ServerResult(outcome: clientResult) }
        var clients = parseClients(clientText, socketPath: socketPath)
        guard clients.count == clientText.split(separator: "\n").count else { return ServerResult(outcome: .invalidOutput) }
        let identityResult = query(["display-message", "-p", "#{pid}\t#{start_time}"])
        guard case let .success(identity) = identityResult else { return ServerResult(outcome: identityResult) }
        let expected = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard panes.allSatisfy({ expected == "\($0.serverPID)\t\($0.serverStartedAt)" })
        else { return ServerResult(outcome: .invalidOutput) }
        for tty in Array(clients.keys) {
            clients[tty]?.serverPID = panes.first?.serverPID
            clients[tty]?.serverStartedAt = panes.first?.serverStartedAt
            clients[tty]?.isProvisional = false
        }
        return ServerResult(outcome: .success(""), panes: panes, clients: clients)
    }

    static func selectPane(tmuxPath: String, location: TmuxPaneLocation) {
        // tmux evaluates this format, not a shell. Check server generation
        // at execution time so a queued click cannot target a reused pane ID.
        let target = "\(location.sessionID):\(location.windowID).\(location.paneID)"
        let condition = "#{&&:#{==:#{pid},\(location.serverPID)},#{==:#{start_time},\(location.serverStartedAt)}}"
        _ = runTmux(
            tmuxPath: tmuxPath, socketPath: location.socketPath,
            arguments: [
                "if-shell", "-F", "-t", target, condition,
                "select-window -t '\(target)' ; select-pane -t '\(target)'"
            ], timeout: 0.5
        )
    }

    /// The tty that input written to a client's tty is delivered to.
    ///
    /// A client writes to the pty in front of the user, but what it types
    /// goes to the active pane of the session it is attached to, which is a
    /// different pty inside the server. Anything that asks the kernel what is
    /// running in the foreground has to ask about that pane, not the client.
    static func activePaneTTY(
        tmuxPath: String,
        socketPath: String,
        sessionID: String,
        timeout: TimeInterval = 0.5
    ) -> String? {
        guard let output = runTmux(
            tmuxPath: tmuxPath,
            socketPath: socketPath,
            // `display-message -p` resolves the target session to its current
            // window's active pane, which is the one receiving input.
            arguments: ["display-message", "-p", "-t", sessionID, "#{pane_tty}"],
            timeout: timeout
        ) else { return nil }
        return parsePaneTTY(output)
    }

    /// `nil` unless tmux answered with one device path. A server that cannot
    /// resolve the target prints an error to stderr and an empty line here.
    static func parsePaneTTY(_ output: String) -> String? {
        guard let line = output.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let tty = String(line)
        guard tty.hasPrefix("/dev/"), !tty.contains(" ") else { return nil }
        return tty
    }

    /// `nil` on any failure — a dead socket, a wedged server, a tmux
    /// that is not there. Every one of them means "no binding for these
    /// panes", which is the same answer as an empty client list, so
    /// none of them is worth surfacing to the user mid-quit.
    private static func runTmux(
        tmuxPath: String,
        socketPath: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> String? {
        let result = TmuxCommand().run(executable: tmuxPath, arguments: ["-S", socketPath] + arguments, timeout: timeout)
        guard case let .success(output) = result else { return nil }
        return output
    }

    /// Sockets inside one server directory.
    ///
    /// Every entry is handed on without checking its file type. tmux is
    /// the authority on whether a path is a socket it can talk to, and
    /// anything else — a directory, a leftover lock file — comes back as
    /// an error we already treat as "no clients here". Filtering first
    /// would only duplicate that judgement.
    static func socketPaths(inServerDirectory directory: URL) -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return contents ?? []
    }

    /// `${TMUX_TMPDIR:-/tmp}/tmux-<uid>`, where tmux puts the default
    /// socket and every `-L <name>` one. A server started with an
    /// `-S <path>` outside this directory is out of scope.
    ///
    /// The `TMUX_TMPDIR` read here is ours, not the user's: launched
    /// from Finder or the Dock we inherit launchd's environment, so a
    /// value they export from their shell rc never reaches us and we
    /// fall back to `/tmp`. That covers the default install; someone
    /// who relocates their sockets loses reattach rather than getting
    /// it wrong. Same blind spot `ToolLocator` documents for `PATH`.
    static func defaultServerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        uid: uid_t = getuid()
    ) -> URL {
        let base = environment["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("tmux-\(uid)", isDirectory: true)
    }
}
