// TmuxSessionProbe.swift
// Limpid — asks a tmux server, after a control client ended, whether the session it showed still exists.

import Darwin
import Foundation

/// What a server says about one session after our client lost it.
enum TmuxSessionPresence: Equatable {
    /// The server answered and lists the session: the client was detached
    /// (for example by `detach-client` elsewhere), the session runs on.
    case exists
    /// The server answered without the session, or no server is there
    /// (`TmuxSessionProbe.isServerAbsent`), so no session can be running.
    case gone
    /// No answer that says either: the server hangs, the socket refuses us
    /// for a reason other than a missing server, or tmux could not be run.
    /// The session may still exist.
    case unknown
}

enum TmuxSessionProbe {
    /// `list-sessions` rather than `has-session`: both exit 1 for a missing
    /// session, a server that is not running, and a socket we cannot open,
    /// and the probe runs with stderr discarded, so only a command that
    /// succeeds whenever the server answers separates "answered without
    /// the session" from "did not answer".
    static func presence(tmuxPath: String, socketPath: String, sessionID: String) -> TmuxSessionPresence {
        let result = TmuxCommand().run(
            executable: tmuxPath,
            arguments: TmuxCommand.clientArguments(socketPath: socketPath, ["list-sessions", "-F", "#{session_id}"])
        )
        return classify(result, sessionID: sessionID) { connectError(socketPath: socketPath) }
    }

    static func classify(
        _ result: TmuxCommandResult,
        sessionID: String,
        connectError: () -> Int32?
    ) -> TmuxSessionPresence {
        if case let .success(output) = result {
            return output.split(whereSeparator: \.isNewline).contains { $0 == sessionID } ? .exists : .gone
        }
        return isServerAbsent(after: result, connectError: connectError) ? .gone : .unknown
    }

    /// Whether a tmux client that got no answer found no server at all.
    /// The one place that tells a stopped server from one we could not
    /// reach; the session check after a connection ended and the check
    /// before a reconnect (`TmuxServerGeneration`) both read it.
    ///
    /// A client that exits non-zero without an answer either found no
    /// server or could not reach one (tmux prints "no server running" or
    /// "error connecting" with the reason). `connectError` repeats tmux's
    /// connect to learn which, and runs only on that path. A missing socket
    /// file and a socket nobody listens on (`ECONNREFUSED`) mean no server:
    /// a refused unix-socket connect is not a passing state, and a server
    /// whose socket file was removed can no longer be reached by anyone, so
    /// its sessions are treated as gone with it (stage 11, "decided in this
    /// stage"). Anything else, such as a permission error or a timeout,
    /// says nothing about whether a server runs.
    static func isServerAbsent(after result: TmuxCommandResult, connectError: () -> Int32?) -> Bool {
        guard case .failed = result, let code = connectError() else { return false }
        return code == ENOENT || code == ECONNREFUSED
    }

    /// A dispatch queue for the same reason as the palette's listing: the
    /// probe blocks on a child process. Formed in this nonisolated function
    /// so Dispatch never runs a closure that carries main-actor isolation.
    nonisolated static func check(tmuxPath: String, socketPath: String, sessionID: String) async -> TmuxSessionPresence {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: presence(tmuxPath: tmuxPath, socketPath: socketPath, sessionID: sessionID))
            }
        }
    }

    /// The `errno` of a stream connect to `socketPath`, or `nil` when
    /// something accepted it. The descriptor is closed before returning.
    static func connectError(socketPath: String) -> Int32? {
        var address = sockaddr_un()
        let path = Array(socketPath.utf8)
        // One byte stays zero as the terminator.
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return ENAMETOOLONG }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return status == 0 ? nil : errno
    }
}
