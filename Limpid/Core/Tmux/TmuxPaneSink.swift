// TmuxPaneSink.swift
// Limpid — one pane's output channel: a socketpair whose far end libghostty reads, fed without ever blocking.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.sink")

/// The host side of one pane's `socketpair(2)`. `surfaceFd` is handed to
/// libghostty's mirror backend at surface creation; everything written
/// here appears as terminal output there, and everything the surface would
/// have written to a pty — key encodings, the VT parser's own replies —
/// arrives on `onSurfaceOutput`.
///
/// Output is only ever the newest state of the pane. Whenever the screen is
/// rebuilt from `capture-pane`, everything tmux sent before that capture is
/// already in it, so it is discarded rather than painted again, whether it
/// arrives during the pause or was still held for a slow reader.
///
/// Deliberately **not** `@MainActor`. Every closure handed to Dispatch is
/// built here, in a nonisolated context; under Swift 6 a `@Sendable`
/// closure formed inside a `@MainActor` method inherits that isolation and
/// Dispatch traps the moment it runs the closure on its own queue.
///
/// All mutable state is confined to `queue`, which is the control
/// connection's routing queue: a pane's bytes are written in the same
/// order they were split off the stream, with no extra hop.
final class TmuxPaneSink: @unchecked Sendable {
    /// Bytes this sink will hold for a stalled reader before giving up.
    /// The design sets 4 MiB: half the largest burst the spike moved and
    /// enough that one `capture-pane` rebuilds the screen afterwards.
    static let defaultLimit = 4 * 1024 * 1024

    /// Descriptor for `ghostty_surface_config_s.mirror_io_fd`. The backend
    /// reads its own duplicate, taken at surface creation, so `close()` may
    /// close ours while the surface lives: closing `hostFd` ends its stream.
    let surfaceFd: Int32

    /// Runs on the main actor with whatever the surface wrote.
    let onSurfaceOutput: @MainActor (Data) -> Void
    /// Runs on the main actor when the held output passed `limit`. The sink
    /// has dropped it and paused itself, so this happens at most once per
    /// pause; the caller rebuilds the screen from tmux and resumes.
    let onOverflow: @MainActor () -> Void

    private let hostFd: Int32
    private let queue: DispatchQueue
    private let limit: Int
    private var pending = Data()
    private var isPaused = false
    /// Counts pauses. An overflow pauses without counting: what it drops
    /// precedes any capture still on its way, so that capture shows it, and
    /// the rebuild the overflow asks for pauses again anyway.
    private var rebuild = 0
    private var isClosed = false
    private var readSource: (any DispatchSourceRead)?
    private var writeSource: (any DispatchSourceWrite)?

    init(
        queue: DispatchQueue,
        limit: Int = TmuxPaneSink.defaultLimit,
        onSurfaceOutput: @escaping @MainActor (Data) -> Void,
        onOverflow: @escaping @MainActor () -> Void
    ) throws {
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
        surfaceFd = fds[0]
        hostFd = fds[1]
        self.queue = queue
        self.limit = limit
        self.onSurfaceOutput = onSurfaceOutput
        self.onOverflow = onOverflow
        // Non-blocking on our side only: the backend's read thread blocks
        // on its end by design, and that is what makes a stalled pane show
        // up here as a full socket rather than as a stuck thread.
        _ = fcntl(hostFd, F_SETFL, fcntl(hostFd, F_GETFL) | O_NONBLOCK)
        armReadSource()
        log.debug("sink opened host=\(self.hostFd, privacy: .public) surface=\(self.surfaceFd, privacy: .public)")
    }

    /// Queue up output for the surface. Must run on `queue`; the transport
    /// calls this from its routing handler. Never blocks: what the socket
    /// will not take now is held in `pending` and drained when it becomes
    /// writable, and past `limit` the held bytes are dropped and the sink
    /// pauses until the screen is rebuilt.
    func write(_ bytes: Data) {
        dispatchPrecondition(condition: .onQueue(queue))
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard !isClosed else { return }
        noteActivity()
        // Paused means a screen capture is on its way. Everything tmux sends
        // before that capture is already in the captured screen, so it is
        // dropped rather than replayed on top of it; a pane whose output was
        // switched off delivers a large batch of exactly that kind when it
        // is switched back on.
        guard !isPaused else { return }
        if !pending.isEmpty {
            append(bytes)
            return
        }
        let written = writeNow(bytes)
        if written < bytes.count {
            append(bytes.dropFirst(written))
            armWriteSource()
        }
    }

    /// Drop output, including what is still held for a slow reader, until
    /// a `resumeInOrder` that names this pause. Used while the screen is
    /// being rebuilt from `capture-pane`. The pause is queued on `queue`,
    /// and so is every command the connection writes, so a capture
    /// requested after this call is written after the pause has taken
    /// effect: everything dropped predates the capture and is already in it.
    func pause() {
        queue.async { [self] in pauseInOrder() }
    }

    /// `pause()` at the current position in the control stream, for the
    /// transport when a line it routes makes the pane's screen stale.
    ///
    /// Every pause is a new rebuild. A capture taken before a later pause
    /// may describe a screen the surface does not have yet, so only the
    /// latest rebuild's capture may end the pause (see `latestRebuild`).
    func pauseInOrder() {
        dispatchPrecondition(condition: .onQueue(queue))
        isPaused = true
        rebuild += 1
        discardPending()
    }

    /// The rebuild the latest pause started. A caller reads it on `queue`
    /// at a point in the stream after which it asks for the capture, and
    /// hands it back to `resumeInOrder`; any pause routed in between makes
    /// that capture stand aside.
    var latestRebuild: Int {
        dispatchPrecondition(condition: .onQueue(queue))
        return rebuild
    }

    /// End a pause at the current position in the control stream. Called on
    /// `queue` from the capture reply's in-stream completion, so the next
    /// `%output` routed to this sink is the first byte tmux sent after the
    /// capture, and it lands after `bytes`. `bytes` is the rebuilt screen,
    /// or `nil` when the rebuild failed and live output is the best the
    /// pane can show.
    ///
    /// Only valid after a pause (or an overflow, which pauses): the
    /// injected screen replaces what was dropped, and on a sink that was
    /// never paused it would land on top of output already shown.
    ///
    /// `rebuild` is the `latestRebuild` the caller read before asking for
    /// the capture. Returns `false`, injecting nothing and staying paused,
    /// when a pause has taken effect since.
    @discardableResult
    func resumeInOrder(injecting bytes: Data?, rebuild: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return false }
        precondition(isPaused, "resumeInOrder without a pause")
        guard rebuild == self.rebuild else { return false }
        pending = bytes ?? Data()
        isPaused = false
        drain()
        return true
    }

    /// `handler` runs on the main actor when output arrives, at most once
    /// per `activityInterval`, and once more after a burst has been quiet
    /// for that long. A mirror uses it to re-check the pane's tty for a
    /// password prompt: the prompt's own output arrives first, and the
    /// program switches the line discipline just after, so the trailing
    /// call is the one that sees the change.
    func setOnOutputActivity(_ handler: (@MainActor () -> Void)?) {
        queue.async { [self] in activityHandler = handler }
    }

    static let activityInterval: Duration = .milliseconds(250)
    private var activityHandler: (@MainActor () -> Void)?
    private var lastActivity: ContinuousClock.Instant?
    private var hasTrailingActivityScheduled = false

    private func noteActivity() {
        guard activityHandler != nil else { return }
        let now = ContinuousClock.now
        if lastActivity.map({ now - $0 >= Self.activityInterval }) ?? true {
            lastActivity = now
            fireActivity()
        }
        guard !hasTrailingActivityScheduled else { return }
        hasTrailingActivityScheduled = true
        let delay = DispatchTimeInterval.milliseconds(Int(Self.activityInterval / .milliseconds(1)))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            hasTrailingActivityScheduled = false
            guard !isClosed else { return }
            lastActivity = ContinuousClock.now
            fireActivity()
        }
    }

    private func fireActivity() {
        guard let activityHandler else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { activityHandler() }
        }
    }

    /// Stop reading the surface's output and close both descriptors. A
    /// surface still showing the pane sees its stream end, since it reads
    /// its own duplicate of `surfaceFd`; after this nothing is delivered.
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            readSource?.cancel()
            writeSource?.cancel()
            readSource = nil
            writeSource = nil
            Darwin.close(hostFd)
            Darwin.close(surfaceFd)
            log.debug("sink closed host=\(self.hostFd, privacy: .public) surface=\(self.surfaceFd, privacy: .public)")
        }
    }

    // MARK: - Queue-confined

    private func append(_ bytes: some DataProtocol) {
        if pending.count + bytes.count > limit {
            // Keep nothing, and take nothing more until the repaint: a
            // partial escape sequence at the cut would corrupt whatever
            // follows, the capture included, and the capture shows all of
            // this output anyway.
            isPaused = true
            discardPending()
            let notify = onOverflow
            DispatchQueue.main.async {
                MainActor.assumeIsolated { notify() }
            }
            log.warning("pane output dropped (over \(self.limit, privacy: .public) bytes pending)")
            return
        }
        pending.append(contentsOf: bytes)
    }

    /// A fresh `Data` rather than `removeAll`, which keeps a slice's
    /// storage around (see `drain`).
    private func discardPending() {
        pending = Data()
        writeSource?.cancel()
        writeSource = nil
    }

    private func writeNow(_ bytes: some DataProtocol) -> Int {
        let data = Data(bytes)
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress, !raw.isEmpty else { return 0 }
            let n = Darwin.write(hostFd, base, raw.count)
            if n < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return 0
                }
                log.error("pane socket write failed errno=\(errno, privacy: .public)")
                return 0
            }
            return n
        }
    }

    /// `removeFirst` on `Data` only moves the start index over the same
    /// storage, and appending keeps growing that storage, so what was
    /// written would stay allocated for the life of the sink. An emptied
    /// buffer is replaced, and one that never empties is copied once its
    /// dead prefix passes `limit`, which keeps the storage under twice it.
    private func drain() {
        guard !isPaused, !pending.isEmpty else { return }
        let n = writeNow(pending)
        pending.removeFirst(n)
        if pending.isEmpty {
            discardPending()
        } else {
            if pending.startIndex > limit {
                pending = Data(pending)
            }
            armWriteSource()
        }
    }

    private func armWriteSource() {
        guard writeSource == nil, !isClosed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: hostFd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        writeSource = source
    }

    private func armReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: hostFd, queue: queue)
        source.setEventHandler { [weak self] in self?.readSurfaceOutput() }
        source.resume()
        readSource = source
    }

    private func readSurfaceOutput() {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(hostFd, $0.baseAddress, $0.count) }
        if n > 0 {
            let data = Data(buffer[0..<n])
            let deliver = onSurfaceOutput
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(data) }
            }
        } else if n == 0 {
            // The surface closed its end. The source keeps reporting a
            // closed descriptor as readable, so tear it down here or the
            // handler spins.
            readSource?.cancel()
            readSource = nil
        }
    }
}

enum TmuxSinkError: Error, Equatable {
    case socketpairFailed(Int32)
}
