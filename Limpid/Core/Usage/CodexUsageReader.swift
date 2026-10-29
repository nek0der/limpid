// CodexUsageReader.swift
// Limpid — asks Codex's app server for the account's plan usage.

import Foundation
import OSLog

private let log = Logger.limpid("usage.codex")

/// What one read of Codex's plan usage found.
enum CodexUsageOutcome: Equatable, Sendable {
    case usage(PlanUsage)
    /// Codex answered with no plan: signed in with an API key, or signed out.
    case noPlan
    /// No `codex` was found where the new worktree sheet looks.
    case notInstalled
    /// Codex did not answer in time, or answered with an error.
    case failed
}

/// Reads Codex's plan usage; the store's seam, so a test hands it outcomes.
protocol CodexUsageReading: Sendable {
    func read() async -> CodexUsageOutcome
}

/// Reads Codex's plan usage the way Codex's own interface does: it starts
/// `codex app-server`, says hello over JSON-RPC, and asks
/// `account/rateLimits/read`. Codex owns the sign-in and its refresh, so we
/// never touch its credentials. The server leaves as soon as its input
/// closes, before it answers, so the input stays open until the answer comes.
struct CodexUsageReader: CodexUsageReading {
    /// How long a read may take before we stop the server. Codex starts in a
    /// fraction of a second; the bound is for a server that hangs on the
    /// network.
    static let timeout: Duration = .seconds(15)

    /// The JSON-RPC id of the usage request, which its answer carries.
    private static let requestID = 2

    func read() async -> CodexUsageOutcome {
        guard let codex = await AgentCatalog.detectInstallations(panePathRecord: nil)
            .first(where: { $0.kind == .codex })
        else { return .notInstalled }
        let loginPath = await (try? LoginShellPath.shared.path()) ?? ProcessInfo.processInfo.environment["PATH"]
        // An npm install is a `node` script, and the folder it was found in
        // holds its `node`. That folder goes after the login shell's, as the
        // shim adds it (`limpid_add_agent_folder`), so a `node` the person
        // chose comes first.
        let folder = URL(fileURLWithPath: codex.executable).deletingLastPathComponent().path
        let path = [loginPath, folder].compactMap(\.self).joined(separator: ":")
        guard let answer = await Self.exchange(executable: codex.executable, path: path) else {
            return .failed
        }
        do {
            switch try LimpidUsageBridge.planUsageAnswer(provider: .codex, answer: answer) {
            case let .usage(usage): return .usage(usage)
            case .noPlan: return .noPlan
            case .unreadable: return .failed
            }
        } catch {
            log.error("codex usage answer unreadable: \(String(describing: error), privacy: .private)")
            return .failed
        }
    }

    /// The request lines, one JSON-RPC message each.
    static var requestLines: Data {
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": ["clientInfo": ["name": "limpid", "version": appVersion]]
            ],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": requestID, "method": "account/rateLimits/read"]
        ]
        var data = Data()
        for message in messages {
            // `try?` because these literals always serialize.
            data.append((try? JSONSerialization.data(withJSONObject: message)) ?? Data())
            data.append(0x0A)
        }
        return data
    }

    /// Codex records the client it serves; ours names this build.
    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Whether `line` is the answer to the usage request, a result or an
    /// error.
    static func isAnswer(_ line: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return false }
        return (object["id"] as? Int) == requestID
    }

    /// Runs the server, sends the requests, and returns the answer's line.
    /// `nil` when the server could not start, ended first, or took longer
    /// than `timeout`.
    static func exchange(executable: String, path: String, timeout: Duration = timeout) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        process.environment = environment
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let wait = AnswerWait {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                wait.finish(nil)
            } else {
                wait.append(chunk)
            }
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // The server starts and gets its requests under the wait's
                // lock, so an ending that comes meanwhile (the panel closing)
                // waits for them and then stops the server, rather than
                // closing its input before the requests are written.
                let start = wait.begin(continuation) {
                    try process.run()
                    let writer = input.fileHandleForWriting
                    // A server that already ended would raise SIGPIPE, which
                    // ends the whole app; the write fails instead.
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    try writer.write(contentsOf: requestLines)
                }
                switch start {
                case .alreadyEnded:
                    continuation.resume(returning: nil)
                case let .failed(error):
                    log.error("codex app-server could not be asked: \(String(describing: error), privacy: .private)")
                    wait.finish(nil)
                case .started:
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                        wait.finish(nil)
                    }
                }
            }
        } onCancel: {
            wait.finish(nil)
        }
    }
}

/// The one ending of an exchange: the answer's line, the server's end, the
/// timeout, or a cancellation, whichever comes first. They arrive on threads
/// of their own, so everything here is under `lock`; `end` stops the server
/// on every path.
private final class AnswerWait: @unchecked Sendable {
    private let lock = NSLock()
    private let end: @Sendable () -> Void
    private var buffer = Data()
    /// Set by `begin`; `nil` before it and after the ending.
    private var continuation: CheckedContinuation<Data?, Never>?
    private var hasEnded = false

    init(end: @escaping @Sendable () -> Void) {
        self.end = end
    }

    /// How `begin` went.
    enum Start {
        case started
        /// The exchange ended before it began (canceled): nothing was run.
        case alreadyEnded
        /// `start` threw; the exchange is still to be finished.
        case failed(any Error)
    }

    /// Takes the continuation the ending resumes and runs `start` (the
    /// server's launch and its requests) under the lock, so `finish` cannot
    /// end the exchange halfway through it.
    func begin(_ continuation: CheckedContinuation<Data?, Never>, start: () throws -> Void) -> Start {
        lock.withLock {
            guard !hasEnded else { return .alreadyEnded }
            self.continuation = continuation
            do {
                try start()
                return .started
            } catch {
                return .failed(error)
            }
        }
    }

    func append(_ chunk: Data) {
        let answer: Data? = lock.withLock {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if CodexUsageReader.isAnswer(line) {
                    return line
                }
            }
            return nil
        }
        if let answer {
            finish(answer)
        }
    }

    /// Ends the exchange once: stops the server and resumes the wait with
    /// `answer`. A later call finds it ended and does nothing.
    func finish(_ answer: Data?) {
        let ending: (isFirst: Bool, continuation: CheckedContinuation<Data?, Never>?) = lock.withLock {
            guard !hasEnded else { return (false, nil) }
            hasEnded = true
            let continuation = self.continuation
            self.continuation = nil
            return (true, continuation)
        }
        guard ending.isFirst else { return }
        end()
        ending.continuation?.resume(returning: answer)
    }
}
