// TmuxSessionProbe.swift
// Limpid — asks a tmux server, after a control client ended, whether the session it showed still exists.

import Darwin
import Foundation

/// What a server says about one session after our client lost it.
enum TmuxSessionPresence: Equatable {
    /// The server answered and lists the session: the client was detached
    /// (for example by `detach-client` elsewhere), the session runs on.
    case exists
    /// The server answered without the session, or nothing listens on the
    /// socket any more, so no session can be running there.
    case gone
    /// No answer we can read: the server hangs, the socket is missing or
    /// refuses us for another reason, or tmux could not be run. The session
    /// may still exist.
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

    /// A tmux client that exits non-zero without an answer either found
    /// nobody listening (`ECONNREFUSED`, tmux prints "no server running")
    /// or could not reach the socket at all (tmux prints "error connecting"
    /// with the reason). Only the first says the server is gone: a socket
    /// file removed under a running server, as a temporary-directory sweep
    /// does, leaves its sessions alive. `connectError` repeats tmux's
    /// connect to learn which, and runs only on that path.
    static func classify(
        _ result: TmuxCommandResult,
        sessionID: String,
        connectError: () -> Int32?
    ) -> TmuxSessionPresence {
        switch result {
        case let .success(output):
            output.split(whereSeparator: \.isNewline).contains { $0 == sessionID } ? .exists : .gone
        case .failed:
            connectError() == ECONNREFUSED ? .gone : .unknown
        case .launchFailed, .timedOut, .cancelled, .invalidOutput, .outputLimit:
            .unknown
        }
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
