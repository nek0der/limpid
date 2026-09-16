// TmuxControlTransport.swift
// Limpid — the byte pipes of one control-mode client: line splitting and pane routing off the main actor.

import Darwin
import Foundation
import OSLog

private let log = Logger.limpid("tmux.transport")

/// Owns the descriptors of a `tmux -C attach` child and the serial queue
/// that reads them. The queue does exactly two things with what it reads:
/// split lines, and route `%output` bytes to the pane's sink. Every other
/// line is parsed and delivered to the main actor in arrival order.
///
/// Deliberately **not** `@MainActor`, for the same reason as
/// `TmuxPaneSink`: the Dispatch closures have to be formed in a
/// nonisolated context or Swift 6 pins them to the main actor and Dispatch
/// traps on its own queue. Ordering is preserved because the receive queue
/// is serial and `DispatchQueue.main.async` is FIFO.
final class TmuxControlTransport: @unchecked Sendable {
    /// Routing queue. Sinks are created on it so their writes need no hop.
    let queue: DispatchQueue

    private let readFd: Int32
    private let writeFd: Int32
    private let writeQueue: DispatchQueue
    private let onLine: @MainActor (TmuxControlLine) -> Void
    private let onEOF: @MainActor () -> Void

    // Queue-confined.
    private var pendingBytes: [UInt8] = []
    private var sinks: [String: TmuxPaneSink] = [:]
    /// Between a `%begin` and its `%end` / `%error`, where a line starting
    /// with `%` is a command's output and not a notification.
    private var insideReplyBlock = false
    private var source: (any DispatchSourceRead)?
    private var isStopped = false

    init(
        readFd: Int32,
        writeFd: Int32,
        onLine: @escaping @MainActor (TmuxControlLine) -> Void,
        onEOF: @escaping @MainActor () -> Void
    ) {
        self.readFd = readFd
        self.writeFd = writeFd
        self.onLine = onLine
        self.onEOF = onEOF
        queue = DispatchQueue(label: "dev.limpid.tmux.control")
        writeQueue = DispatchQueue(label: "dev.limpid.tmux.control.write")
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: readFd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
        queue.async { [self] in self.source = source }
    }

    func stop() {
        queue.async { [self] in
            guard !isStopped else { return }
            isStopped = true
            source?.cancel()
            source = nil
        }
    }

    /// Route a pane's `%output` bytes to `sink`, or stop routing them with
    /// `nil`. Applied on the queue so it lands between two whole lines,
    /// never in the middle of one.
    func setSink(_ sink: TmuxPaneSink?, forPane pane: String) {
        queue.async { [self] in
            sinks[pane] = sink
        }
    }

    /// Write one command line to tmux. A separate queue, because a write
    /// that blocks (tmux busy flushing to us) must not stall the reader
    /// that would relieve it.
    func send(_ line: String) {
        let bytes = Array((line + "\n").utf8)
        let fd = writeFd
        writeQueue.async {
            var offset = 0
            while offset < bytes.count {
                let n = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                }
                if n > 0 {
                    offset += n
                } else if n < 0, errno == EAGAIN || errno == EINTR {
                    // The reader is behind. Yield instead of spinning.
                    usleep(1000)
                } else {
                    log.error("control write failed errno=\(errno, privacy: .public)")
                    return
                }
            }
        }
    }

    // MARK: - Queue-confined

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(readFd, $0.baseAddress, $0.count) }
        if n > 0 {
            pendingBytes.append(contentsOf: buffer[0..<n])
            routeCompleteLines()
        } else if n == 0 {
            // EOF. The source keeps reporting a closed descriptor as
            // readable, so it has to be torn down here or the handler spins.
            source?.cancel()
            source = nil
            let finish = onEOF
            DispatchQueue.main.async {
                MainActor.assumeIsolated { finish() }
            }
        } else if errno != EAGAIN, errno != EINTR {
            log.error("control read failed errno=\(errno, privacy: .public)")
        }
    }

    private func routeCompleteLines() {
        var start = pendingBytes.startIndex
        while let newline = pendingBytes[start...].firstIndex(of: 0x0A) {
            let line = TmuxProtocol.parseLine(pendingBytes[start..<newline], insideReplyBlock: insideReplyBlock)
            start = newline + 1
            switch line {
            case .begin: insideReplyBlock = true
            case .end, .error: insideReplyBlock = false
            default: break
            }
            if case let .output(pane, bytes) = line {
                sinks[pane]?.write(bytes)
                continue
            }
            let deliver = onLine
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(line) }
            }
        }
        if start > pendingBytes.startIndex {
            pendingBytes.removeFirst(start - pendingBytes.startIndex)
        }
    }
}
