// TmuxCommand.swift
// Limpid — bounded, cancellable execution of our own tmux client processes.

import Foundation

enum TmuxTiming {
    static let queryTimeout: TimeInterval = 0.5
    static let terminationGrace: TimeInterval = 0.2
    static let drainGrace: TimeInterval = 0.2
    static let pollBudget: TimeInterval = 2
    static let snapshotLifetime: TimeInterval = 6
    static let readPollMilliseconds: Int32 = 10
    static let outputLimit = 2 * 1024 * 1024
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

/// The lock protects launch/cancellation and every access to the owned Process.
/// Only run() owns the pipe descriptor and output buffer. No borrowed FFI state
/// crosses threads, and each instance executes at most one command.
final class TmuxCommand: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var isCancelled = false
    private var hasStarted = false

    func cancel() {
        lock.withLock { isCancelled = true }
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = TmuxTiming.queryTimeout,
        outputLimit: Int = TmuxTiming.outputLimit
    ) -> TmuxCommandResult {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close() }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        if let failure = launch(executable: executable, arguments: arguments, pipe: pipe) {
            return failure
        }
        // The parent must not keep a writer alive after its child exits.
        try? pipe.fileHandleForWriting.close()
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            stopOwnedProcess(force: true)
            return .invalidOutput
        }
        var output = OutputState()
        var stopDeadline: TimeInterval?
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if output.failure == nil {
                if lock.withLock({ isCancelled }) {
                    output.failure = .cancelled
                } else if now >= deadline {
                    output.failure = .timedOut
                }
            }
            if output.failure != nil, stopDeadline == nil {
                stopOwnedProcess(force: false)
                stopDeadline = now + TmuxTiming.terminationGrace
            }
            if let stopDeadline, now >= stopDeadline {
                stopOwnedProcess(force: true)
                if now >= stopDeadline + TmuxTiming.drainGrace {
                    break
                }
            }
            output.readChunk(fd: fd, limit: outputLimit)
            if output.shouldFinish(isRunning: lock.withLock { process.isRunning }, now: now) {
                break
            }
            // Nonblocking reads and a bounded poll avoid a reader task that
            // outlives the command when a descendant retains the write end.
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            if output.hasReachedEOF {
                _ = poll(nil, 0, TmuxTiming.readPollMilliseconds)
            } else {
                _ = poll(&descriptor, 1, TmuxTiming.readPollMilliseconds)
            }
        }
        return result(for: output)
    }

    private func result(for output: OutputState) -> TmuxCommandResult {
        if let failure = output.failure {
            return failure
        }
        let status = lock.withLock { process.terminationStatus }
        guard status == 0 else { return .failed(status) }
        guard let text = String(data: output.bytes, encoding: .utf8) else { return .invalidOutput }
        return .success(text)
    }

    private func launch(executable: String, arguments: [String], pipe: Pipe) -> TmuxCommandResult? {
        lock.withLock {
            guard !isCancelled else { return .cancelled }
            guard !hasStarted else { return .launchFailed }
            hasStarted = true
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do { try process.run() } catch { return .launchFailed }
            return nil
        }
    }

    private struct OutputState {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        var failure: TmuxCommandResult?
        var hasReachedEOF = false
        var exitObservedAt: TimeInterval?

        mutating func readChunk(fd: Int32, limit: Int) {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                if count > max(0, limit) - bytes.count {
                    failure = .outputLimit
                } else {
                    bytes.append(contentsOf: buffer.prefix(count))
                }
            } else if count == 0 {
                hasReachedEOF = true
            } else if errno != EAGAIN, errno != EINTR {
                failure = failure ?? .invalidOutput
            }
        }

        mutating func shouldFinish(isRunning: Bool, now: TimeInterval) -> Bool {
            guard !isRunning else { return false }
            if hasReachedEOF {
                return true
            }
            if exitObservedAt == nil {
                exitObservedAt = now
            }
            if now - (exitObservedAt ?? now) >= TmuxTiming.drainGrace {
                failure = failure ?? .timedOut
                return true
            }
            return false
        }
    }

    private func stopOwnedProcess(force: Bool) {
        lock.withLock {
            guard process.isRunning else { return }
            if force {
                kill(process.processIdentifier, SIGKILL)
            } else {
                process.terminate()
            }
        }
    }
}
