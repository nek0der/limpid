// TmuxCommand.swift
// Limpid — bounded, cancellable execution of our own tmux client processes.

import Foundation
import Synchronization

enum TmuxTiming {
    static let queryTimeout: TimeInterval = 0.5
    static let terminationGrace: TimeInterval = 0.2
    static let drainGrace: TimeInterval = 0.2
    static let pollBudget: TimeInterval = 2
    static let snapshotLifetime: TimeInterval = 6
    static let readPollMilliseconds: Int32 = 10
    static let outputLimit = 2 * 1024 * 1024

    /// The graces above, as the shared runner takes them. Short, because the
    /// client is asked many times within `pollBudget`.
    static let drain = ProcessDrainTiming(
        terminationGrace: .seconds(terminationGrace),
        drainGrace: .seconds(drainGrace),
        pollMilliseconds: readPollMilliseconds
    )
}

enum TmuxCommandResult: Equatable {
    case success(String)
    case launchFailed
    case failed(Int32)
    case timedOut
    case cancelled
    case invalidOutput
    case outputLimit
}

/// One tmux client run, on the shared runner (`drainAndWait`) with tmux's
/// own timeout, graces, and output cap. Each instance runs at most one
/// command; `cancel` may come from another thread, before or during it.
final class TmuxCommand: Sendable {
    private let stop = ProcessStopRequest()
    private let hasStarted = Mutex(false)

    func cancel() {
        stop.request()
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = TmuxTiming.queryTimeout,
        outputLimit: Int = TmuxTiming.outputLimit
    ) -> TmuxCommandResult {
        guard !stop.isRequested else { return .cancelled }
        // A second run of the same instance is refused: its cancellation
        // would reach a run it was not meant for.
        let isSecondRun = hasStarted.withLock { started in
            defer { started = true }
            return started
        }
        guard !isSecondRun else { return .launchFailed }
        let process = Process()
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .launchFailed }
        // The parent must not keep a writer alive after its child exits.
        try? pipe.fileHandleForWriting.close()
        let output = drainAndWait(
            process,
            stdout: pipe,
            stderr: nil,
            timeout: .seconds(max(0, timeout)),
            stop: stop,
            stdoutLimitBytes: outputLimit,
            timing: TmuxTiming.drain
        )
        return Self.result(of: output, status: process.terminationStatus)
    }

    /// What the run comes to. A client that exited while something it left
    /// behind still held its output gave no whole answer in time.
    private static func result(of output: DrainedOutput, status: Int32) -> TmuxCommandResult {
        switch output.ending {
        case .stopped: return .cancelled
        case .timedOut: return .timedOut
        case .outputLimit: return .outputLimit
        case .exited: break
        }
        if output.hasStdoutReadFailed {
            return .invalidOutput
        }
        guard output.isStdoutComplete else { return .timedOut }
        guard status == 0 else { return .failed(status) }
        guard let text = String(data: output.stdout, encoding: .utf8) else { return .invalidOutput }
        return .success(text)
    }
}
