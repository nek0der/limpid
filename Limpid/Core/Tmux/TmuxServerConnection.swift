// TmuxServerConnection.swift
// Limpid — one `tmux -C attach` client per server: the process, its replies, and the panes it feeds.

import Foundation
import OSLog

private let log = Logger.limpid("tmux.connection")

/// A control-mode client attached to one tmux server. The protocol carries
/// every window and pane of the session over this single pipe, so the
/// connection belongs to the server, not to a pane; panes plug in as sinks.
///
/// Lifecycle and state run on the main actor. The bytes do not: the
/// transport splits lines, pairs replies, and feeds pane sinks on its own
/// queue, and only the attach result, notifications, and main-delivered
/// replies are hopped here, in order.
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
        /// tmux ended the connection (a refused attach, `%exit`, a killed
        /// server, or our own `stop()`); `reason` is the attach block's
        /// error or the text after `%exit`, whichever came first. Final:
        /// nothing leaves this state.
        case exited(reason: String?)
    }

    typealias ReplyHandler = @MainActor (_ lines: [String], _ isError: Bool) -> Void

    let target: Target
    private(set) var state: State = .connecting
    /// Whether tmux ever accepted the attach. `.exited` alone cannot tell
    /// a refused attach from a session that ended later, and only the
    /// latter means the session may be gone; a refusal says nothing about
    /// the session beyond that we never reached it.
    private(set) var hasAttached = false
    /// Every notification that is not a reply marker or pane output:
    /// `%layout-change`, `%window-pane-changed`, `%exit`, and the rest.
    var onNotification: ((TmuxControlLine) -> Void)?
    /// Every change of `state`, including the exit our own `stop()` causes.
    var onStateChange: ((State) -> Void)?

    private let executable: String
    private var process: Process?

    /// The pid tmux reports for this client as `#{client_pid}`, so a listing
    /// of a session's clients can tell this connection apart from another
    /// app's. Nil until `start` has spawned the client and once it has
    /// exited: the system can hand a finished client's pid to another
    /// process, whose client would then pass for ours.
    var clientPID: pid_t? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    /// Exists before `start` so commands sent early are held by it until
    /// the attach block closes.
    private let transport = TmuxControlTransport()
    private(set) var sinks: [String: TmuxPaneSink] = [:]
    /// The server's version, once it has answered. Gates the commands an
    /// older server would refuse.
    private(set) var version: TmuxVersion?
    /// The colors the attached panes' programs are told about. Reported to
    /// every attached pane when it changes, and to each pane on attach.
    var terminalColors: TerminalColors? {
        didSet {
            guard terminalColors != oldValue else { return }
            for pane in sinks.keys {
                reportColors(toPane: pane)
            }
        }
    }

    /// Keystrokes waiting for the end of this main-actor turn, and whether
    /// that end has been scheduled. Every other command flushes them first,
    /// so nothing overtakes a key typed before it.
    private var pendingInput = TmuxInputBatch()
    private var isInputFlushScheduled = false

    init(executable: String, target: Target) {
        self.executable = executable
        self.target = target
    }

    /// Spawn the client. The transport starts reading immediately; the
    /// attach block arrives within milliseconds and flips `state`. A client
    /// that cannot be spawned ends the connection like any other end, so
    /// commands sent before this fail with the reason, and the error is
    /// still thrown.
    func start() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["-S", target.socketPath, "-C", "attach", "-t", target.sessionID]
        let stdin = Pipe()
        let stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        let errorPipe = Pipe()
        proc.standardError = errorPipe
        proc.terminationHandler = Self.terminationHandler(errorOutput: errorPipe.fileHandleForReading, connection: self)
        do {
            try proc.run()
        } catch {
            setState(.exited(reason: error.localizedDescription))
            throw error
        }
        process = proc

        // `run` has already closed the child's ends on our side. The
        // transport takes its own duplicates of ours, so we close these at
        // once: the only write end left is then the transport's, and its
        // `close` is what gives tmux EOF.
        let readHandle = stdout.fileHandleForReading
        let writeHandle = stdin.fileHandleForWriting
        transport.start(
            readFd: readHandle.fileDescriptor,
            writeFd: writeHandle.fileDescriptor,
            events: .init(
                attachFinished: { [weak self] lines, isError in self?.attachFinished(lines: lines, isError: isError) },
                notification: { [weak self] line in self?.handle(line) },
                endOfStream: { [weak self] in self?.handleEOF() }
            )
        )
        // Closing a pipe end we own cannot fail in a way we could act on.
        try? readHandle.close()
        try? writeHandle.close()
        log.notice("spawned socket=\(self.target.socketPath, privacy: .private) session=\(self.target.sessionID, privacy: .public)")
        send("display-message -p '#{version}'") { [weak self] lines, isError in
            guard let self, !isError, let version = lines.first.flatMap(TmuxProtocol.parseVersion) else { return }
            self.version = version
            for pane in sinks.keys {
                reportColors(toPane: pane)
            }
        }
    }

    /// Built outside the main actor on purpose: `Process` calls it on its
    /// own queue, and a closure formed in a main-actor method would inherit
    /// that isolation and trap there (see `TmuxPaneSink`).
    private nonisolated static func terminationHandler(
        errorOutput: FileHandle,
        connection: TmuxServerConnection
    ) -> @Sendable (Process) -> Void {
        { [weak connection] process in
            // The child is gone, so its end of the pipe is closed and this
            // read stops at EOF. tmux's client writes to stderr only when it
            // gives up, right before exiting, so the pipe cannot fill up
            // while the client runs and nobody reads it.
            let output = errorOutput.readDataToEndOfFile()
            let status = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    connection?.handleTermination(status: status, stderr: output)
                }
            }
        }
    }

    /// Send one command whose reply nobody reads.
    func send(_ command: String) {
        flushInput()
        transport.send(command, completion: nil)
    }

    /// Send one command. `completion` receives the reply block's lines and
    /// whether tmux answered with `%error`, on the main actor. On a closed
    /// connection it receives the exit reason as an error.
    func send(_ command: String, completion: @escaping ReplyHandler) {
        flushInput()
        transport.send(command, completion: .onMain(completion))
    }

    /// Send one command whose reply must be handled at its place in the
    /// stream: `completion` runs on the routing queue before the next line
    /// is routed. It must be formed outside the main actor.
    func sendInStream(_ command: String, completion: @escaping @Sendable (_ lines: [String], _ isError: Bool) -> Void) {
        flushInput()
        transport.send(command, completion: .inStream(completion))
    }

    /// Type into a pane. Input from one main-actor turn goes out together
    /// when the turn ends; there is no timer, so a lone keystroke is not
    /// held back either (design m4).
    func sendInput(_ inputs: [TmuxInput], pane: String) {
        guard !inputs.isEmpty else { return }
        for input in inputs {
            pendingInput.append(input, pane: pane)
        }
        guard !isInputFlushScheduled else { return }
        isInputFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushInput()
        }
    }

    private func flushInput() {
        isInputFlushScheduled = false
        guard !pendingInput.isEmpty else { return }
        for command in pendingInput.drain() {
            transport.send(command, completion: nil)
        }
    }

    /// Tell tmux the colors `pane`'s programs should see, once both the
    /// server's version and the colors are known. An ended connection has
    /// nobody to tell; sending would only fail and log a refusal tmux never
    /// made.
    private func reportColors(toPane pane: String) {
        if case .exited = state {
            return
        }
        guard let version, TmuxColorReport.isSupported(by: version), let terminalColors else { return }
        for command in TmuxColorReport.commands(pane: pane, colors: terminalColors) {
            send(command) { lines, isError in
                guard isError else { return }
                log.error("color report refused: \(lines.joined(separator: " "), privacy: .private)")
            }
        }
    }

    /// Create the sink for `pane` and route its `%output` there. What the
    /// surface still writes (mouse and focus reports; keys arrive through
    /// `sendInput`) goes to the pane as bytes, and `onOverflow` goes to
    /// whoever attached it, the only party that can repaint that pane. A
    /// pane already attached is refused: tmux feeds one sink per pane, and
    /// two owners of it would close it under each other.
    func attachPane(
        _ pane: String,
        limit: Int = TmuxPaneSink.defaultLimit,
        onOverflow: @escaping @MainActor () -> Void
    ) throws -> TmuxPaneSink {
        guard process != nil else { throw TmuxConnectionError.notStarted }
        guard sinks[pane] == nil else { throw TmuxConnectionError.paneAlreadyAttached(pane) }
        let sink = try TmuxPaneSink(
            queue: transport.queue,
            limit: limit,
            onSurfaceOutput: { [weak self] data in self?.sendInput([.bytes(Array(data))], pane: pane) },
            onOverflow: onOverflow
        )
        sinks[pane] = sink
        transport.setSink(sink, forPane: pane)
        reportColors(toPane: pane)
        return sink
    }

    /// Stop routing to `pane` and close its sink. A surface still showing
    /// the pane is unaffected beyond seeing the stream end: libghostty
    /// reads its own duplicate of `surfaceFd`.
    func detachPane(_ pane: String) {
        guard let sink = sinks.removeValue(forKey: pane) else { return }
        transport.setSink(nil, forPane: pane)
        sink.close()
    }

    /// End the client. The child is terminated explicitly rather than left
    /// to exit on EOF: a detached control client keeps the server's
    /// bookkeeping for it alive until it is gone.
    func stop() {
        for pane in Array(sinks.keys) {
            detachPane(pane)
        }
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        setState(.exited(reason: nil))
    }

    // MARK: - Inbound

    /// The transport has already written the commands it held when the
    /// attach succeeded, and keeps holding them when it did not.
    private func attachFinished(lines: [String], isError: Bool) {
        guard !isError else {
            let reason = lines.isEmpty ? nil : lines.joined(separator: " ")
            log.error("attach refused: \(reason ?? "", privacy: .private)")
            setState(.exited(reason: reason))
            return
        }
        log.notice("attached session=\(self.target.sessionID, privacy: .public)")
        setState(.attached)
    }

    private func handle(_ line: TmuxControlLine) {
        switch line {
        case let .exit(reason):
            setState(.exited(reason: reason))
            onNotification?(line)
        default:
            onNotification?(line)
        }
    }

    /// The end of the connection when tmux did not say so first. EOF is
    /// the signal rather than the process exit because the transport
    /// delivers it after every line it read, so a refused attach or an
    /// `%exit` is always handled before it.
    private func handleEOF() {
        setState(.exited(reason: nil))
    }

    /// Only a log. The status and stderr are the sole record of why a
    /// client that never spoke the protocol (a bad socket, a missing
    /// server) went away. The state is left to `handleEOF`: this handler
    /// reaches the main actor on its own schedule, possibly before lines
    /// the transport has not delivered yet, such as the attach block's
    /// `%error`.
    private func handleTermination(status: Int32, stderr: Data) {
        let message = TmuxProtocol.lossyText(Array(stderr)[...]).trimmingCharacters(in: .whitespacesAndNewlines)
        log.notice("client exited status=\(status, privacy: .public) stderr=\(message, privacy: .private)")
    }

    private func setState(_ new: State) {
        // The first exit wins: `%exit` and EOF both follow a refused attach,
        // and neither may replace its reason.
        if case .exited = state {
            return
        }
        guard new != state else { return }
        state = new
        if new == .attached {
            hasAttached = true
        }
        switch new {
        case .connecting, .attached:
            log.notice("state \(String(describing: new), privacy: .public)")
        case let .exited(reason):
            log.notice("state exited reason=\(reason ?? "", privacy: .private)")
        }
        onStateChange?(new)
        if case let .exited(reason) = new {
            // Only this first exit reaches the transport, so every pending
            // command fails once, with the reason `state` shows.
            transport.close(failingPendingWith: [reason ?? "connection closed"])
        }
    }
}

enum TmuxConnectionError: Error, Equatable {
    case notStarted
    case paneAlreadyAttached(String)
}
