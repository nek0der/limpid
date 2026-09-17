// TmuxPaneSink.swift
// Limpid — one connection's writes into a pane's channel: held, paused, and rebuilt without ever blocking.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.sink")

/// What one connection writes into a pane's `TmuxPaneChannel`. Everything
/// written here appears as terminal output on the surface reading that
/// channel. The sink owns no descriptor and closes none: the channel
/// belongs to the leaf and outlives the connection, so a later connection
/// can attach a sink of its own to the same surface.
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

    /// The stream this sink writes. Held for the sink's life, and past it
    /// by a write source until that source's cancel handler has run, so its
    /// host descriptor stays open while Dispatch watches it.
    let channel: TmuxPaneChannel

    /// Runs on the main actor when the held output passed `limit`. The sink
    /// has dropped it and paused itself, so this happens at most once per
    /// pause; the caller rebuilds the screen from tmux and resumes.
    let onOverflow: @MainActor () -> Void

    private let queue: DispatchQueue
    private let limit: Int
    private var pending = Data()
    private var isPaused = false
    /// Counts pauses. An overflow pauses without counting: what it drops
    /// precedes any capture still on its way, so that capture shows it, and
    /// the rebuild the overflow asks for pauses again anyway.
    private var rebuild = 0
    private var isClosed = false
    private var writeSource: (any DispatchSourceWrite)?

    init(
        channel: TmuxPaneChannel,
        queue: DispatchQueue,
        limit: Int = TmuxPaneSink.defaultLimit,
        onOverflow: @escaping @MainActor () -> Void
    ) {
        self.channel = channel
        self.queue = queue
        self.limit = limit
        self.onOverflow = onOverflow
        log.debug("sink attached host=\(channel.hostFd, privacy: .public)")
    }

    /// An owner that never called `close` still stops watching the socket.
    /// Nothing else can reach the source once the sink is gone.
    deinit {
        writeSource?.cancel()
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
        guard !isClosed else { return }
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
    /// never paused it would land on top of output already shown. A resume
    /// on a sink that is not paused injects nothing and returns `false`, so
    /// the caller treats it as it treats a superseded capture.
    ///
    /// `rebuild` is the `latestRebuild` the caller read before asking for
    /// the capture. Returns `false`, injecting nothing and staying paused,
    /// when a pause has taken effect since.
    @discardableResult
    func resumeInOrder(injecting bytes: Data?, rebuild: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isClosed else { return false }
        guard isPaused else {
            log.error("resume without a pause host=\(self.channel.hostFd, privacy: .public)")
            return false
        }
        guard rebuild == self.rebuild else { return false }
        pending = bytes ?? Data()
        isPaused = false
        drain()
        return true
    }

    /// `handler` runs on the main actor when output arrives, at most once
    /// per `activityInterval`, and once more when the output has been
    /// quiet for that long since its last write. A mirror uses it to
    /// re-check the pane's tty for a password prompt: the prompt's own
    /// output arrives first, and the program switches the line discipline
    /// just after, so the trailing call is the one that sees the change.
    func setOnOutputActivity(_ handler: (@MainActor () -> Void)?) {
        queue.async { [self] in activityHandler = handler }
    }

    static let activityInterval: Duration = .milliseconds(250)
    private var activityHandler: (@MainActor () -> Void)?
    /// When the handler last ran, which spaces out the calls during a burst.
    private var lastActivityCall: ContinuousClock.Instant?
    /// When output last arrived, which the trailing call waits to be
    /// `activityInterval` behind.
    private var lastOutput: ContinuousClock.Instant?
    private var hasTrailingActivityScheduled = false

    private func noteActivity() {
        guard activityHandler != nil else { return }
        let now = ContinuousClock.now
        lastOutput = now
        if lastActivityCall.map({ now - $0 >= Self.activityInterval }) ?? true {
            lastActivityCall = now
            fireActivity()
        }
        scheduleTrailingActivity(after: Self.activityInterval)
    }

    /// One wake-up is pending at a time. It fires once the output has been
    /// quiet for `activityInterval`; output that arrived meanwhile moves it
    /// to that interval after the latest write.
    private func scheduleTrailingActivity(after delay: Duration) {
        guard !hasTrailingActivityScheduled else { return }
        hasTrailingActivityScheduled = true
        let milliseconds = Int((delay / .milliseconds(1)).rounded(.up))
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { [weak self] in
            guard let self else { return }
            hasTrailingActivityScheduled = false
            guard !isClosed, let lastOutput else { return }
            let now = ContinuousClock.now
            let quiet = now - lastOutput
            guard quiet >= Self.activityInterval else {
                scheduleTrailingActivity(after: Self.activityInterval - quiet)
                return
            }
            lastActivityCall = now
            fireActivity()
        }
    }

    private func fireActivity() {
        guard let activityHandler else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { activityHandler() }
        }
    }

    /// Stop writing and drop whatever is held. The channel stays open, so
    /// the surface keeps its screen and its stream: another sink may feed
    /// it next. After this nothing is written or reported.
    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            discardPending()
            log.debug("sink detached host=\(self.channel.hostFd, privacy: .public)")
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

    /// Takes `Data` rather than any `DataProtocol`, so the held output is
    /// written from its own storage instead of a copy of all of it.
    ///
    /// Only a full socket is retried. Any other failure is permanent — the
    /// surface's end is gone, or the descriptor is not what we think it is
    /// — and retrying it would spin, because a write source keeps reporting
    /// such a descriptor as writable. The sink gives up there, the same way
    /// `TmuxPaneChannel` stops reading, and the caller checks `isClosed`.
    private func writeNow(_ data: Data) -> Int {
        guard !isClosed else { return 0 }
        let result = data.withUnsafeBytes { raw -> (written: Int, failure: Int32?) in
            guard let base = raw.baseAddress, !raw.isEmpty else { return (0, nil) }
            let n = Darwin.write(channel.hostFd, base, raw.count)
            guard n < 0 else { return (n, nil) }
            let code = errno
            return (0, code == EAGAIN || code == EWOULDBLOCK ? nil : code)
        }
        if let failure = result.failure {
            failWriting(errno: failure)
        }
        return result.written
    }

    /// Stop writing for good and tell the owner, which marks the pane as
    /// having lost output. Nothing repaints it: the stream the surface
    /// reads is what failed, and a surface created for the leaf later opens
    /// a channel of its own.
    private func failWriting(errno code: Int32) {
        guard !isClosed else { return }
        isClosed = true
        discardPending()
        log.error("""
        pane socket write failed host=\(self.channel.hostFd, privacy: .public) \
        errno=\(code, privacy: .public); this sink stops writing
        """)
        let notify = onOverflow
        DispatchQueue.main.async {
            MainActor.assumeIsolated { notify() }
        }
    }

    /// `removeFirst` on `Data` only moves the start index over the same
    /// storage, and appending keeps growing that storage, so what was
    /// written would stay allocated for the life of the sink. An emptied
    /// buffer is replaced, and one that never empties is copied once its
    /// dead prefix passes `limit`, which keeps the storage under twice it.
    private func drain() {
        guard !isPaused, !isClosed, !pending.isEmpty else { return }
        let n = writeNow(pending)
        guard !isClosed else { return }
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
        let channel = channel
        let source = DispatchSource.makeWriteSource(fileDescriptor: channel.hostFd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        // The channel closes its descriptors when released. Holding it here
        // until the source has stopped watching is what keeps that close
        // after this cancel, whichever of the sink and the channel's other
        // owners lets go first.
        source.setCancelHandler { withExtendedLifetime(channel) {} }
        source.resume()
        writeSource = source
    }
}

enum TmuxSinkError: Error, Equatable {
    case socketpairFailed(Int32)
}
