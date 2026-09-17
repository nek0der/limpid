// TmuxPaneChannel.swift
// Limpid — the socketpair one mirror pane's surface reads for as long as its leaf exists.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.channel")

/// The stream a mirror leaf's surface reads instead of a pty. libghostty's
/// mirror backend duplicates `surfaceFd` when the surface is created and
/// reads that duplicate until the far end closes; a surface whose stream
/// ended never reads again. So the stream belongs to the leaf, not to a
/// connection: whatever connection feeds the pane attaches a
/// `TmuxPaneSink` that writes into `hostFd`, and a later connection
/// attaches another sink to the same channel.
///
/// What the surface writes back (mouse and focus reports; keys reach tmux
/// as actions instead) arrives on `onSurfaceOutput`, whichever connection
/// feeds the pane, or none.
///
/// Closed by being released, never by a call. Both descriptors are closed
/// in the read source's cancel handler, which `deinit` triggers, so
/// nothing that still holds the channel can see its descriptor numbers
/// reused. A sink holds the channel until its own write source has been
/// cancelled (see `TmuxPaneSink`), which keeps the host end open for as
/// long as Dispatch watches it there too.
///
/// Deliberately **not** `@MainActor`, for the same reason as
/// `TmuxPaneSink`: the Dispatch closures are formed here, in a nonisolated
/// context.
final class TmuxPaneChannel: @unchecked Sendable {
    /// Descriptor for `ghostty_surface_config_s.mirror_io_fd`. Valid for
    /// the life of this object.
    let surfaceFd: Int32
    /// Our end. Non-blocking: sinks write it without waiting, and a stalled
    /// surface shows up as a full socket rather than a stuck thread. Valid
    /// for the life of this object.
    let hostFd: Int32

    /// One queue for every channel's reads. The work per read is a copy and
    /// a hop to the main actor, and a serial queue per descriptor keeps each
    /// surface's output in order.
    private static let readQueue = DispatchQueue(label: "dev.limpid.tmux.channel")

    private let readSource: any DispatchSourceRead

    init(onSurfaceOutput: @escaping @MainActor (Data) -> Void) throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw TmuxSinkError.socketpairFailed(errno)
        }
        // Close-on-exec on both ends: libghostty forks a shell for every
        // ordinary pane without sweeping descriptors, and an inherited copy
        // would keep the stream open after we close ours and let that
        // shell read or type into the mirrored pane.
        for fd in fds {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        let surfaceFd = fds[0]
        let hostFd = fds[1]
        _ = fcntl(hostFd, F_SETFL, fcntl(hostFd, F_GETFL) | O_NONBLOCK)
        self.surfaceFd = surfaceFd
        self.hostFd = hostFd

        let source = DispatchSource.makeReadSource(fileDescriptor: hostFd, queue: Self.readQueue)
        // Captures the descriptor, not `self`: the source outlives the
        // channel by the time it takes its cancel handler to run. We hold
        // `surfaceFd` open until then, so the host end never reads EOF and
        // the handler cannot spin on a closed stream.
        source.setEventHandler {
            Self.readSurfaceOutput(from: hostFd, deliver: onSurfaceOutput)
        }
        // The documented place to close a source's descriptor: the source
        // no longer watches it once this runs.
        source.setCancelHandler {
            Darwin.close(hostFd)
            Darwin.close(surfaceFd)
            log.debug("channel closed host=\(hostFd, privacy: .public) surface=\(surfaceFd, privacy: .public)")
        }
        source.resume()
        readSource = source
        log.debug("channel opened host=\(hostFd, privacy: .public) surface=\(surfaceFd, privacy: .public)")
    }

    deinit {
        readSource.cancel()
    }

    private static func readSurfaceOutput(from fd: Int32, deliver: @escaping @MainActor (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return }
        let data = Data(buffer[0..<n])
        DispatchQueue.main.async {
            MainActor.assumeIsolated { deliver(data) }
        }
    }
}
