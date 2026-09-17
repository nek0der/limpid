// TmuxControlTransport.swift
// Limpid — the byte pipes of one control-mode client: line splitting, reply pairing, and pane routing off the main actor.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.transport")

/// Owns the descriptors of a `tmux -C attach` child and the serial queue
/// that reads them. It reads and writes only its own duplicates of the
/// descriptors it is started with, and closes each one on the queue that
/// uses it, so no command or read can reach a descriptor number that has
/// been closed and handed to a different stream.
///
/// The queue splits lines, routes `%output` bytes to the pane's sink, and
/// pairs every reply block with the command that asked for it, all in
/// stream order. Notifications are parsed and delivered to the main actor
/// in arrival order.
///
/// Pairing lives here rather than on the main actor so that a reply can be
/// acted on at the exact position of its closing marker: an `.inStream`
/// completion runs before the line after `%end` is routed, which is what
/// lets a pane sink resume with a captured screen and lose none of the
/// output tmux sent after the capture.
///
/// Deliberately **not** `@MainActor`, for the same reason as
/// `TmuxPaneSink`: the Dispatch closures have to be formed in a
/// nonisolated context or Swift 6 pins them to the main actor and Dispatch
/// traps on its own queue. Ordering is preserved because the routing queue
/// is serial and `DispatchQueue.main.async` is FIFO.
final class TmuxControlTransport: @unchecked Sendable {
    /// Where a reply's completion runs.
    enum Completion: Sendable {
        /// On the main actor, after every line routed before the reply.
        case onMain(@MainActor (_ lines: [String], _ isError: Bool) -> Void)
        /// Synchronously on `queue`, before the next line is routed. Must
        /// be formed in a nonisolated context and touch no main-actor state.
        case inStream(@Sendable (_ lines: [String], _ isError: Bool) -> Void)
    }

    /// What the connection learns from the stream, delivered on the main
    /// actor in stream order.
    struct Events: Sendable {
        /// The attach block closed; with `isError` tmux refused the attach
        /// and `lines` says why.
        let attachFinished: @MainActor (_ lines: [String], _ isError: Bool) -> Void
        /// Every line that is neither pane output nor part of a reply.
        let notification: @MainActor (TmuxControlLine) -> Void
        /// The read end reached EOF, after every line before it.
        let endOfStream: @MainActor () -> Void
    }

    /// Routing queue. Sinks are created on it so their writes need no hop.
    let queue = DispatchQueue(label: "dev.limpid.tmux.control")
    /// A write that blocks (tmux busy flushing to us) must not stall the
    /// reader that would relieve it.
    private let writeQueue = DispatchQueue(label: "dev.limpid.tmux.control.write")

    private enum Phase {
        /// Commands are held unwritten, so a refused attach fails them with
        /// tmux's reason instead of writing them into an exiting client.
        case connecting
        case attached
        /// Every later command fails at once with `reply`.
        case closed(reply: [String])
    }

    // Queue-confined.
    /// Our duplicate of the write end; `nil` before `start` and after
    /// `close`, so nothing can be written once the connection has ended.
    private var writeFd: Int32?
    private var events: Events?
    private var phase = Phase.connecting
    private var held: [(line: String, completion: Completion?)] = []
    /// Completions of written commands in the order they were written.
    /// tmux answers in that order, one flags-1 block each; blocks it emits
    /// on its own never reach this queue (see `TmuxReplyAssembler`).
    private var waiting: [Completion?] = []
    private var assembler = TmuxReplyAssembler()
    /// Bytes read after the last whole line: the start of a line whose
    /// newline has not arrived.
    private var pendingBytes: [UInt8] = []
    /// How many leading bytes of `pendingBytes` are known to hold no
    /// newline, so a long line arriving in many reads is searched once
    /// rather than from its start on every read.
    private var scannedCount = 0
    private var sinks: [String: TmuxPaneSink] = [:]
    private var source: (any DispatchSourceRead)?

    /// The longest line we wait for. The longest line tmux sends a mirror is
    /// a `capture-pane -e` row: tmux caps a window at 10000 columns, and a
    /// cell whose colors and attributes all differ from its neighbor's
    /// takes well under 100 bytes, so a row stays under 1 MiB. The rest is
    /// headroom for what that estimate leaves out, such as hyperlinks. A
    /// stream past this is not tmux speaking the protocol, and holding it
    /// would only grow without bound, so the connection ends there.
    static let lineLimit = 8 * 1024 * 1024

    /// Start reading `readFd` and writing `writeFd`. Both are duplicated
    /// before this returns, so the caller closes its own copies whenever
    /// it likes; the duplicates are close-on-exec, because libghostty
    /// forks shells without sweeping descriptors and an inherited write
    /// end would keep tmux from ever seeing EOF.
    func start(readFd: Int32, writeFd: Int32, events: Events) {
        let ownRead = fcntl(readFd, F_DUPFD_CLOEXEC, 0)
        let ownWrite = fcntl(writeFd, F_DUPFD_CLOEXEC, 0)
        let isDuplicated = ownRead >= 0 && ownWrite >= 0
        if !isDuplicated {
            log.error("control descriptors not duplicated errno=\(errno, privacy: .public)")
        }
        queue.async { [self] in
            guard isDuplicated, case .connecting = phase, source == nil else {
                for fd in [ownRead, ownWrite] where fd >= 0 {
                    Darwin.close(fd)
                }
                // With nothing to read, the stream has already ended.
                if !isDuplicated {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { events.endOfStream() }
                    }
                }
                return
            }
            self.writeFd = ownWrite
            self.events = events
            let source = DispatchSource.makeReadSource(fileDescriptor: ownRead, queue: queue)
            source.setEventHandler { [weak self] in self?.drain(ownRead) }
            // The documented place to close a source's descriptor: the
            // source no longer watches it once this runs.
            source.setCancelHandler { Darwin.close(ownRead) }
            source.resume()
            self.source = source
        }
    }

    /// Stop reading and fail every command still unanswered, and every one
    /// sent later, with `reply`. The first call wins. The write end is
    /// closed behind the writes already queued, which is also what tells
    /// tmux the client is done.
    func close(failingPendingWith reply: [String]) {
        queue.async { [self] in
            if case .closed = phase {
                return
            }
            phase = .closed(reply: reply)
            releaseDescriptors()
            let failed = held.map(\.completion) + waiting
            held.removeAll()
            waiting.removeAll()
            for completion in failed {
                completion.map { Self.complete($0, lines: reply, isError: true) }
            }
        }
    }

    /// An owner that never called `close` still gives the descriptors back.
    /// No block on `queue` can be pending here: each one holds `self`.
    deinit {
        releaseDescriptors()
    }

    /// Route a pane's `%output` bytes to `sink`, or stop routing them with
    /// `nil`. Applied on the queue so it lands between two whole lines,
    /// never in the middle of one.
    func setSink(_ sink: TmuxPaneSink?, forPane pane: String) {
        queue.async { [self] in
            sinks[pane] = sink
        }
    }

    /// Write one command line to tmux. The completion is queued on the
    /// routing queue before the line is handed to the writer, so it exists
    /// before any byte of its reply can be read.
    func send(_ line: String, completion: Completion?) {
        queue.async { [self] in
            switch phase {
            case .connecting:
                held.append((line, completion))
            case .attached:
                waiting.append(completion)
                write(line)
            case let .closed(reply):
                completion.map { Self.complete($0, lines: reply, isError: true) }
            }
        }
    }

    // MARK: - Queue-confined

    private func releaseDescriptors() {
        source?.cancel()
        source = nil
        if let fd = writeFd {
            writeFd = nil
            writeQueue.async { Darwin.close(fd) }
        }
    }

    private func write(_ line: String) {
        guard let fd = writeFd else { return }
        let bytes = Array((line + "\n").utf8)
        writeQueue.async {
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                // The descriptor blocks: nothing on either side sets
                // `O_NONBLOCK` on our end of the pipe, and tmux's own flags
                // live on its end, a separate open file. A slow reader
                // makes the write wait rather than fail, so only a signal
                // interrupts it.
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EINTR {
                    continue
                } else {
                    log.error("control write failed errno=\(errno, privacy: .public)")
                    return
                }
            }
        }
    }

    private func drain(_ readFd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(readFd, $0.baseAddress, $0.count) }
        if n > 0 {
            pendingBytes.append(contentsOf: buffer[0..<n])
            routeCompleteLines()
            if pendingBytes.count > Self.lineLimit {
                log.error("control line longer than \(Self.lineLimit, privacy: .public) bytes; ending the connection")
                pendingBytes = []
                scannedCount = 0
                endStream()
            }
        } else if n == 0 {
            endStream()
        } else if errno != EAGAIN, errno != EINTR {
            log.error("control read failed errno=\(errno, privacy: .public)")
        }
    }

    /// Stop reading and report the end after every line already routed.
    /// The source keeps reporting a closed descriptor as readable, so at
    /// EOF it has to be torn down here or the handler spins.
    private func endStream() {
        source?.cancel()
        source = nil
        guard let finish = events?.endOfStream else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { finish() }
        }
    }

    private func routeCompleteLines() {
        var start = 0
        var searchFrom = scannedCount
        while let newline = pendingBytes[searchFrom...].firstIndex(of: 0x0A) {
            let line = TmuxProtocol.parseLine(pendingBytes[start..<newline], openBlock: assembler.openBlock)
            start = newline + 1
            searchFrom = start
            if case let .output(pane, bytes) = line {
                sinks[pane]?.write(bytes)
                continue
            }
            if let event = assembler.consume(line) {
                handle(event)
                continue
            }
            switch line {
            case .begin, .end, .error, .text:
                continue
            case let .layoutChange(_, layout, _, _):
                // tmux has resized these panes, and a capture it answers
                // from here on is taken at the new size, which the surface
                // may not have yet. Pausing here, in stream order, keeps
                // such a capture from being painted; the mirror repaints
                // once the surface has caught up. The layout lists every
                // pane of the window; a pane with no sink is not shown.
                for pane in TmuxLayout.parse(layout)?.root.paneIDs ?? [] {
                    sinks[pane]?.pauseInOrder()
                }
                fallthrough
            default:
                guard let deliver = events?.notification else { continue }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { deliver(line) }
                }
            }
        }
        if start > 0 {
            pendingBytes.removeFirst(start)
        }
        scannedCount = pendingBytes.count
    }

    private func handle(_ event: TmuxReplyAssembler.Event) {
        switch event {
        case let .attachFinished(lines, isError):
            if !isError, case .connecting = phase {
                phase = .attached
                let queued = held
                held.removeAll()
                for entry in queued {
                    waiting.append(entry.completion)
                    write(entry.line)
                }
            }
            guard let finish = events?.attachFinished else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish(lines, isError) }
            }
        case let .reply(lines, isError, marker):
            if isError {
                let reason = lines.joined(separator: " | ")
                log.error("tmux command \(marker.number, privacy: .public) failed: \(reason, privacy: .private)")
            }
            guard !waiting.isEmpty, let completion = waiting.removeFirst() else { return }
            Self.complete(completion, lines: lines, isError: isError)
        }
    }

    private static func complete(_ completion: Completion, lines: [String], isError: Bool) {
        switch completion {
        case let .onMain(handler):
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(lines, isError) }
            }
        case let .inStream(handler):
            handler(lines, isError)
        }
    }
}
