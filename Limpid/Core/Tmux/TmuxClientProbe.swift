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
    /// Tab-separated because a session name may contain spaces, which
    /// tmux permits. Only the first two fields are structural.
    static let listClientsArguments = [
        "list-clients", "-F", "#{client_tty}\t#{session_id}\t#{session_name}"
    ]

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
        var clients: [String: TmuxBinding] = [:]
        for socket in socketPaths(inServerDirectory: serverDirectory) {
            guard let output = runTmux(
                tmuxPath: tmuxPath, socketPath: socket.path, timeout: timeout
            ) else { continue }
            // Later servers win a tty collision, which cannot happen:
            // one tty drives at most one client.
            clients.merge(parseClients(output, socketPath: socket.path)) { _, new in new }
        }
        return clients
    }

    /// `nil` on any failure — a dead socket, a wedged server, a tmux
    /// that is not there. Every one of them means "no binding for these
    /// panes", which is the same answer as an empty client list, so
    /// none of them is worth surfacing to the user mid-quit.
    private static func runTmux(
        tmuxPath: String,
        socketPath: String,
        timeout: TimeInterval
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-S", socketPath] + listClientsArguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // `terminate` is what unblocks `waitUntilExit`; a timer alone
        // would fire and leave us still waiting. The `isRunning` check
        // is not redundant with `cancel()` below: a process that exits
        // just before the deadline leaves a window in which the pid may
        // already have been recycled, and signalling it then would
        // reach somebody else.
        let watchdog = DispatchWorkItem { [weak process] in
            guard let process, process.isRunning else { return }
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Read before waiting: a server with many clients can fill the
        // pipe buffer, and a child blocked on write never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
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
