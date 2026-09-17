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
/// Closed by being released, never by a call. Both descriptors belong to a
/// `Descriptors` that the channel and the read source's cancel handler
/// share, and close when the later of the two lets go, so nothing that
/// still holds the channel can see its descriptor numbers reused, and the
/// read source never watches a closed one. A sink holds the channel until
/// its own write source has been cancelled (see `TmuxPaneSink`), which
/// keeps the host end open for as long as Dispatch watches it there too.
///
/// A read that fails stops the reading, and only the reading: the source
/// is cancelled, which leaves the descriptors to the channel, so sinks keep
/// writing the surface's output. The failure would otherwise repeat on
/// every wake-up of a source that stays readable.
///
/// Deliberately **not** `@MainActor`, for the same reason as
/// `TmuxPaneSink`: the Dispatch closures are formed here, in a nonisolated
/// context.
final class TmuxPaneChannel: @unchecked Sendable {
    /// Descriptor for `ghostty_surface_config_s.mirror_io_fd`. Valid for
    /// the life of this object.
    var surfaceFd: Int32 {
        descriptors.surfaceFd
    }

    /// Our end. Non-blocking: sinks write it without waiting, and a stalled
    /// surface shows up as a full socket rather than a stuck thread. Valid
    /// for the life of this object.
    var hostFd: Int32 {
        descriptors.hostFd
    }

    /// Both ends of the socketpair, closed when the last owner lets go.
    private final class Descriptors: Sendable {
        let surfaceFd: Int32
        let hostFd: Int32

        init(surfaceFd: Int32, hostFd: Int32) {
            self.surfaceFd = surfaceFd
            self.hostFd = hostFd
        }

        deinit {
            Darwin.close(hostFd)
            Darwin.close(surfaceFd)
            log.debug("channel closed host=\(self.hostFd, privacy: .public) surface=\(self.surfaceFd, privacy: .public)")
        }
    }

    /// What one read of the host end came to.
    enum ReadResult: Equatable {
        case delivered(Data)
        /// Nothing to read now; the source reports the next bytes.
        case wouldBlock
        /// The read failed for good, or the stream ended; reading stops.
        case failed(errno: Int32)
        case ended
    }

    /// One queue for every channel's reads. The work per read is a copy and
    /// a hop to the main actor, and a serial queue per descriptor keeps each
    /// surface's output in order.
    private static let readQueue = DispatchQueue(label: "dev.limpid.tmux.channel")

    private let descriptors: Descriptors
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
        let descriptors = Descriptors(surfaceFd: fds[0], hostFd: fds[1])
        let hostFd = descriptors.hostFd
        _ = fcntl(hostFd, F_SETFL, fcntl(hostFd, F_GETFL) | O_NONBLOCK)
        self.descriptors = descriptors

        let source = DispatchSource.makeReadSource(fileDescriptor: hostFd, queue: Self.readQueue)
        // Captures the descriptor, not `self`: the source outlives the
        // channel by the time it takes its cancel handler to run. We hold
        // `surfaceFd` open until then, so the host end never reads EOF
        // while the channel exists. The source is captured weakly: it owns
        // this handler until it is cancelled.
        source.setEventHandler { [weak source] in
            switch Self.readSurfaceOutput(from: hostFd) {
            case let .delivered(data):
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onSurfaceOutput(data) }
                }
            case .wouldBlock:
                break
            case let .failed(code):
                log.error("channel read failed host=\(hostFd, privacy: .public) errno=\(code, privacy: .public); reading stops")
                source?.cancel()
            case .ended:
                log.error("channel read reached EOF host=\(hostFd, privacy: .public); reading stops")
                source?.cancel()
            }
        }
        // The descriptors stay open until this has run: the source no
        // longer watches them once it does.
        source.setCancelHandler { withExtendedLifetime(descriptors) {} }
        source.resume()
        readSource = source
        log.debug("channel opened host=\(hostFd, privacy: .public) surface=\(descriptors.surfaceFd, privacy: .public)")
    }

    deinit {
        readSource.cancel()
    }

    /// Read what the surface wrote to `fd` once. Interrupted and empty reads
    /// are retried by the source's next wake-up; anything else ends the
    /// reading.
    static func readSurfaceOutput(from fd: Int32) -> ReadResult {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if n > 0 {
            return .delivered(Data(buffer[0..<n]))
        }
        if n == 0 {
            return .ended
        }
        let code = errno
        return code == EAGAIN || code == EINTR ? .wouldBlock : .failed(errno: code)
    }
}
