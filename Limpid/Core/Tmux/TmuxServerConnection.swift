// TmuxServerConnection.swift
// Limpid — one `tmux -C attach` client per server: the process, its replies, and the panes it feeds.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.connection")

/// A control-mode client attached to one tmux server. The protocol carries
/// every window and pane of the session over this single pipe, so the
/// connection belongs to the server, not to a pane; panes plug in as sinks.
///
/// Everything here runs on the main actor. The bytes do not: the transport
/// splits lines and feeds pane sinks on its own queue, and only parsed
/// notifications and reply markers are hopped here, in order.
@MainActor
final class TmuxServerConnection {
    struct Target: Equatable {
        /// Absolute socket path (`-S`). Addressed by path rather than `-L`
        /// because a server started with `-S` is only reachable this way.
        let socketPath: String
        /// `$N`; a name can be reused by a different session, an id cannot.
        let sessionID: String
    }

    enum State: Equatable {
        case connecting
        case attached
        /// tmux ended the connection (`%exit`, a killed server, or our own
        /// `stop()`); `reason` is whatever tmux printed after `%exit`.
        case exited(reason: String?)
    }

    typealias ReplyHandler = (_ lines: [String], _ isError: Bool) -> Void

    let target: Target
    private(set) var state: State = .connecting
    /// Every notification that is not a reply marker or pane output:
    /// `%layout-change`, `%window-pane-changed`, `%exit`, and the rest.
    var onNotification: ((TmuxControlLine) -> Void)?
    var onStateChange: ((State) -> Void)?
    /// A pane's sink dropped output; the screen has to be rebuilt.
    var onPaneOverflow: ((String) -> Void)?

    private let executable: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var transport: TmuxControlTransport?
    private var assembler = TmuxReplyAssembler()
    /// Completion handlers in the order their commands were sent. tmux
    /// answers in that order, one `%begin` block each.
    private var waiting: [ReplyHandler?] = []
    /// Commands sent before the attach block closed. tmux emits that block
    /// on its own; a command written before it would pair with the wrong
    /// reply, so we hold them until `attachFinished`.
    private var queuedCommands: [(command: String, completion: ReplyHandler?)] = []
    private(set) var sinks: [String: TmuxPaneSink] = [:]

    init(executable: String, target: Target) {
        self.executable = executable
        self.target = target
    }

    /// Spawn the client. The transport starts reading immediately; the
    /// attach block arrives within milliseconds and flips `state`.
    func start() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["-S", target.socketPath, "-C", "attach", "-t", target.sessionID]
        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleTermination() }
            }
        }
        try proc.run()
        process = proc
        stdinPipe = stdin
        stdoutPipe = stdout

        let transport = TmuxControlTransport(
            readFd: stdout.fileHandleForReading.fileDescriptor,
            writeFd: stdin.fileHandleForWriting.fileDescriptor,
            onLine: { [weak self] line in self?.handle(line) },
            onEOF: { [weak self] in self?.handleEOF() }
        )
        transport.start()
        self.transport = transport
        log.notice("attached socket=\(self.target.socketPath, privacy: .private) session=\(self.target.sessionID, privacy: .public)")
    }

    /// Send one command. `completion` receives the reply block's lines and
    /// whether tmux answered with `%error`.
    func send(_ command: String, completion: ReplyHandler? = nil) {
        if case .exited = state {
            completion?(["connection closed"], true)
            return
        }
        guard assembler.hasSeenAttachBlock else {
            queuedCommands.append((command, completion))
            return
        }
        waiting.append(completion)
        transport?.send(command)
    }

    /// Type bytes into a pane. Hex avoids every quoting problem the raw
    /// bytes would have on tmux's command parser.
    func sendKeys(pane: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        send("send-keys -t \(pane) -H \(TmuxProtocol.hexKeyArguments(bytes))")
    }

    /// Create the sink for `pane` and route its `%output` there. The
    /// surface's own output comes back as keystrokes for the pane; an
    /// overflow is reported through `onPaneOverflow`.
    func attachPane(_ pane: String, limit: Int = TmuxPaneSink.defaultLimit) throws -> TmuxPaneSink {
        guard let transport else { throw TmuxConnectionError.notStarted }
        if let existing = sinks[pane] { return existing }
        let sink = try TmuxPaneSink(
            queue: transport.queue,
            limit: limit,
            onSurfaceOutput: { [weak self] data in self?.sendKeys(pane: pane, bytes: data) },
            onOverflow: { [weak self] in self?.onPaneOverflow?(pane) }
        )
        sinks[pane] = sink
        transport.setSink(sink, forPane: pane)
        return sink
    }

    /// Stop routing to `pane` and close its sink. The surface that borrowed
    /// `surfaceFd` must be gone first.
    func detachPane(_ pane: String) {
        guard let sink = sinks.removeValue(forKey: pane) else { return }
        transport?.setSink(nil, forPane: pane)
        sink.close()
    }

    /// End the client. The child is terminated explicitly rather than left
    /// to exit on EOF: a detached control client keeps the server's
    /// bookkeeping for it alive until it is gone.
    func stop() {
        for pane in Array(sinks.keys) {
            detachPane(pane)
        }
        transport?.stop()
        transport = nil
        try? stdinPipe?.fileHandleForWriting.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        if case .exited = state { return }
        setState(.exited(reason: nil))
    }

    // MARK: - Inbound

    private func handle(_ line: TmuxControlLine) {
        if let event = assembler.consume(line) {
            switch event {
            case .attachFinished:
                setState(.attached)
                let pending = queuedCommands
                queuedCommands.removeAll()
                for entry in pending {
                    send(entry.command, completion: entry.completion)
                }
            case let .reply(lines, isError, marker):
                if isError {
                    log.error("tmux command \(marker.number, privacy: .public) failed: \(lines.joined(separator: " | "), privacy: .public)")
                }
                if !waiting.isEmpty {
                    let completion = waiting.removeFirst()
                    completion?(lines, isError)
                }
            }
            return
        }
        switch line {
        case .begin, .end, .error, .text:
            return
        case let .exit(reason):
            setState(.exited(reason: reason))
            onNotification?(line)
        default:
            onNotification?(line)
        }
    }

    private func handleEOF() {
        if case .exited = state { return }
        setState(.exited(reason: nil))
    }

    private func handleTermination() {
        if case .exited = state { return }
        setState(.exited(reason: nil))
    }

    private func setState(_ new: State) {
        guard new != state else { return }
        state = new
        log.notice("state \(String(describing: new), privacy: .public)")
        onStateChange?(new)
        if case .exited = new {
            for entry in queuedCommands {
                entry.completion?(["connection closed"], true)
            }
            queuedCommands.removeAll()
            for completion in waiting {
                completion?(["connection closed"], true)
            }
            waiting.removeAll()
        }
    }
}

enum TmuxConnectionError: Error, Equatable {
    case notStarted
}
