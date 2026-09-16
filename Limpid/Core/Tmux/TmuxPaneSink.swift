// TmuxPaneSink.swift
// Limpid — one pane's output channel: a socketpair whose far end libghostty reads, fed without ever blocking.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.sink")

/// The host side of one pane's `socketpair(2)`. `surfaceFd` is handed to
/// libghostty's mirror backend at surface creation and stays put for the
/// surface's life; everything written here appears as terminal output
/// there, and everything the surface would have written to a pty — key
/// encodings, the VT parser's own replies — arrives on `onSurfaceOutput`.
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
    /// borrows it and never closes it.
    let surfaceFd: Int32

    /// Runs on the main actor with whatever the surface wrote.
    let onSurfaceOutput: @MainActor (Data) -> Void
    /// Runs on the main actor once per overflow: the pending output was
    /// dropped and the caller has to rebuild the screen from tmux.
    let onOverflow: @MainActor () -> Void

    private let hostFd: Int32
    private let queue: DispatchQueue
    private let limit: Int
    private var pending = Data()
    private var isPaused = false
    private var hasReportedOverflow = false
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
    /// writable, and past `limit` the held bytes are dropped instead.
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

    /// Drop output until `resume()`. Used while the screen is being rebuilt
    /// from `capture-pane`: what arrives meanwhile predates the capture, and
    /// painting it again would duplicate it. Output that tmux emits after
    /// the capture reply but before `resume` runs on this queue is lost as
    /// well; that window is one hop through the main actor.
    func pause() {
        queue.async { [self] in isPaused = true }
    }

    func resume() {
        queue.async { [self] in
            isPaused = false
            drain()
        }
    }

    /// Resume with `bytes` placed ahead of anything a stalled reader left
    /// pending. This is how a rebuilt screen (`capture-pane`) lands as one
    /// piece before live output starts flowing again.
    func resume(afterInjecting bytes: Data) {
        queue.async { [self] in
            pending.insert(contentsOf: bytes, at: pending.startIndex)
            isPaused = false
            drain()
        }
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

    /// Stop reading the surface's output and close our end. `surfaceFd` is
    /// closed too, because after this nothing legitimate can use it; the
    /// surface must already be gone.
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
            // Keep nothing: a partial escape sequence at the cut would
            // corrupt whatever follows, and the caller repaints anyway.
            pending.removeAll(keepingCapacity: false)
            if !hasReportedOverflow {
                hasReportedOverflow = true
                let notify = onOverflow
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { notify() }
                }
            }
            log.warning("pane output dropped (over \(self.limit, privacy: .public) bytes pending)")
            return
        }
        pending.append(contentsOf: bytes)
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

    private func drain() {
        guard !isPaused, !pending.isEmpty else { return }
        let n = writeNow(pending)
        pending.removeFirst(n)
        if pending.isEmpty {
            hasReportedOverflow = false
            writeSource?.cancel()
            writeSource = nil
        } else {
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
