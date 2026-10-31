// ProcessDrain.swift
// Limpid — run a child process to completion without deadlocking on
// its pipes, and end it when it outlives its time.
//
// macOS pipe buffers are bounded (~16-64 KB). A child that writes
// more than that blocks in `write(2)` until something reads, so
// draining only after `waitUntilExit()` returns means the child never
// exits and the caller parks forever. `git status --porcelain=v2`
// against a dirty repo with hundreds of untracked files is the
// realistic case; `gh pr view --json` payloads are smaller today but
// a future `gh run view --log-failed` would not be.
//
// Two more ways a run used to outlive any limit we set: a child that
// ignores SIGTERM, and a child that exits while something it started
// (a login shell's `ssh-agent`, a hook's background job) still holds
// its stdout, so the pipe never reaches EOF. The loop below ends both:
// SIGKILL follows SIGTERM after a grace, and reading stops a moment
// after the child itself has exited.
//
// The one runner for every bounded child Limpid starts: `GitProcess`,
// the optional-tool path, the review's Git queries (`ReviewGitCommand`),
// and the tmux client (`TmuxCommand`). Each keeps its own timeout, its
// graces (`ProcessDrainTiming`), and an output cap where it has one, and
// reads what the run reports as its own result; what differs between
// them — throwing, returning nil, or a result enum — is a deliberate
// difference in posture and stays with each caller.

import Foundation

/// Asks a run from another thread to stop: a canceled task's handler
/// sets it, and the loop in `drainAndWait` ends the child. A lock rather
/// than an actor because the cancellation handler must not suspend.
final class ProcessStopRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var hasStopRequest = false

    var isRequested: Bool {
        lock.withLock { hasStopRequest }
    }

    func request() {
        lock.withLock { hasStopRequest = true }
    }
}

extension Pipe {
    /// A pipe for one child, whose ends no other process inherits.
    ///
    /// Foundation leaves a pipe's descriptors open across `exec`, and a
    /// `fork` on another thread (a terminal's shell) copies every descriptor
    /// the process holds. A copy of the write end keeps the pipe from ever
    /// reaching EOF for as long as that process lives, so a Git that has
    /// finished reads as one that timed out. The child still gets its end:
    /// `dup2` onto its standard streams clears the flag on the copy. macOS has
    /// no `pipe2`, so a fork between the pipe's creation and these calls can
    /// still copy it; the window is what is left, not the whole run.
    static func forChildProcess() -> Pipe {
        let pipe = Pipe()
        _ = fcntl(pipe.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        return pipe
    }
}

/// How a run handed to `drainAndWait` ended. The first reason found to
/// end it is the one reported.
enum ProcessEnding: Equatable {
    /// The child exited on its own.
    case exited
    /// It was still running at its timeout and was ended.
    case timedOut
    /// Its `ProcessStopRequest` was set and it was ended.
    case stopped
    /// Its stdout passed the run's cap. It was ended if it still ran, and
    /// what it wrote past the cap was read and dropped.
    case outputLimit
}

/// What a run wrote, and how it ended.
struct DrainedOutput {
    let stdout: Data
    let stderr: Data
    let ending: ProcessEnding
    /// Whether stdout was read to its end. `false` when reading stopped
    /// with the pipe still open (something the child started still held it
    /// past the drain grace), or when a read failed; either way `stdout` may
    /// be missing its tail. Always `true` for a run with no stdout pipe.
    let isStdoutComplete: Bool
    /// Whether a read of stdout failed, rather than the pipe being left open.
    let hasStdoutReadFailed: Bool
    /// Whether something the run started was still running when it was
    /// given up on: it was ended for a reason of ours, and part of its
    /// process group outlived SIGKILL. Only a child with a group of its own
    /// (`GroupedProcess`) can say; for any other it is `false`.
    let hasProcessesLeft: Bool
}

/// This is a launched child that `drainAndWait` waits for and ends.
protocol DrainedChild: AnyObject {
    /// Whether the child itself still runs.
    var isRunning: Bool { get }
    /// Sends `signal` to the child, or to its whole process group where it
    /// has one of its own.
    func send(_ signal: Int32)
    /// Whether anything is left in the child's process group once the child
    /// itself has exited; always `false` for a child with no group of its
    /// own, where there is nothing to look at.
    var hasGroupMembersLeft: Bool { get }
    /// Blocks until the child has exited, and reaps it.
    func waitUntilExit()
}

/// Foundation's `Process` starts its child in Limpid's own process group,
/// so only the child is signaled: there is no group to signal without
/// signaling Limpid.
extension Process: DrainedChild {
    func send(_ signal: Int32) {
        let pid = processIdentifier
        guard pid > 0 else { return }
        kill(pid, signal)
    }

    var hasGroupMembersLeft: Bool {
        false
    }
}

/// This is a child started with `posix_spawn` as the leader of a process
/// group of its own, so ending it ends what it started too: the hook a git
/// command runs, and the hook's own jobs. `Process` has no way to start one so.
///
/// Its stdin is the null device, and it inherits no descriptor of ours but
/// the two pipes. It is not `Sendable`: only the one thread that runs
/// `drainAndWait` uses it.
final class GroupedProcess: DrainedChild {
    let pid: pid_t
    /// This is the child's exit code, or the signal that ended it, as
    /// `Process` reports `terminationStatus`. It is -1 until the child is
    /// reaped, and stays -1 when another waiter reaped it first.
    private(set) var terminationStatus: Int32 = -1
    private var isReaped = false

    private init(pid: pid_t) {
        self.pid = pid
    }

    /// Starts `executable` with `arguments` in `directory`, with exactly
    /// `environment`. Throws the `posix_spawn` error when it cannot start.
    static func launch( // swiftlint:disable:this function_parameter_count
        _ executable: URL,
        arguments: [String],
        environment: [String: String],
        in directory: URL,
        stdout: Pipe,
        stderr: Pipe
    ) throws -> GroupedProcess {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, 2)
        posix_spawn_file_actions_addchdir(&actions, directory.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // We set signals as a new program expects them, whatever Limpid
        // blocks or ignores: an ignored SIGPIPE or SIGTERM would otherwise
        // be inherited.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var everySignal = sigset_t()
        sigfillset(&everySignal)
        sigdelset(&everySignal, SIGKILL)
        sigdelset(&everySignal, SIGSTOP)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        // Group 0 gives the child a group of its own, named by its pid.
        posix_spawnattr_setpgroup(&attributes, 0)
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attributes, Int16(flags))

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv + envp {
                free(pointer)
            }
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        // The child has its own copies of the write ends; ours would keep
        // the pipes from ever reaching EOF.
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        guard code == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return GroupedProcess(pid: pid)
    }

    /// Reaps the child once it has exited.
    var isRunning: Bool {
        !reap(blocking: false)
    }

    func waitUntilExit() {
        _ = reap(blocking: true)
    }

    /// `drainAndWait` signals the group only while something is left in it:
    /// a group's number is not given to a new process while the group is
    /// there.
    func send(_ signal: Int32) {
        kill(-pid, signal)
    }

    /// We look at the group only once the child is reaped: until then the
    /// child itself, exited but not reaped, is still in the group.
    var hasGroupMembersLeft: Bool {
        guard isReaped else { return true }
        return ProcessLiveness.hasLiveMembers(group: pid)
    }

    /// Whether the child has exited, reaping it if so.
    private func reap(blocking: Bool) -> Bool {
        guard !isReaped else { return true }
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, blocking ? 0 : WNOHANG)
            if result == pid {
                // We decode the status by hand: `WIFEXITED`, `WEXITSTATUS`,
                // and `WTERMSIG` are macros Swift does not import.
                terminationStatus = status & 0x7F == 0 ? (status >> 8) & 0xFF : status & 0x7F
                isReaped = true
                return true
            }
            if result == 0 {
                return false
            }
            if errno == EINTR {
                continue
            }
            // ECHILD means another waiter reaped it, so it has exited.
            isReaped = true
            return true
        }
    }
}

/// The graces a run is held to. Each caller keeps its own: a tmux query
/// is asked many times a second and must give up quickly, where a Git
/// call is let finish writing.
struct ProcessDrainTiming {
    /// How long a child has after SIGTERM before SIGKILL.
    var terminationGrace: Duration
    /// How long the pipes are read after the child has exited. What it
    /// wrote is already in the pipe and is read at once; past this, the
    /// writer is something it left behind, which we do not wait for.
    var drainGrace: Duration
    /// How long one wait for output lasts before the loop looks at the
    /// child, its timeout, and its stop request again. Output wakes the
    /// wait at once, so this is how late an exit, a deadline, or a stop is
    /// seen; a shorter one only spends wakeups on runs that sit quiet.
    var pollMilliseconds: Int32

    /// The graces of `GitProcess` and the optional tools.
    static let standard = ProcessDrainTiming(
        terminationGrace: .seconds(2),
        drainGrace: .milliseconds(300),
        pollMilliseconds: 50
    )
}

/// Waits for a launched `process` while draining both pipes, and returns
/// once the child has exited and its pipes have reached EOF or gone quiet
/// for `timing.drainGrace`. Past `timeout`, once `stop` is set, or once
/// stdout passes `stdoutLimitBytes`, the child gets SIGTERM, then SIGKILL
/// after `timing.terminationGrace`. A `nil` pipe is one the caller pointed
/// elsewhere (a file, the null device). Blocks: call it from a background
/// queue.
///
/// A `Process` is signaled alone: Foundation starts it in Limpid's own
/// process group, so there is no group to signal without signaling
/// Limpid. A grandchild (a hook's background job, `sleep` under a shell
/// that traps SIGTERM) outlives the run; we only stop waiting for it.
///
/// A `GroupedProcess` is ended with its whole group, and once ended for a
/// reason of ours it is waited for until nothing is left in the group: the
/// group gets SIGKILL after the grace even when the child itself has
/// exited, as a shell does on SIGTERM while its job ignores it. What
/// outlives SIGKILL by another grace is reported (`hasProcessesLeft`), so
/// the caller does not take the run's folder for free. Something that left
/// the group (`setsid`) cannot be seen.
func drainAndWait(
    _ process: some DrainedChild,
    stdout: Pipe?,
    stderr: Pipe?,
    timeout: Duration? = nil,
    stop: ProcessStopRequest? = nil,
    stdoutLimitBytes: Int? = nil,
    timing: ProcessDrainTiming = .standard
) -> DrainedOutput {
    var streams = [
        PipeReader(fd: stdout?.fileHandleForReading.fileDescriptor, limitBytes: stdoutLimitBytes),
        PipeReader(fd: stderr?.fileHandleForReading.fileDescriptor, limitBytes: nil)
    ]
    let clock = ContinuousClock()
    let deadline = timeout.map { clock.now + $0 }
    var ending = ProcessEnding.exited
    var signaledAt: ContinuousClock.Instant?
    var hasKilled = false
    var exitedAt: ContinuousClock.Instant?
    var hasProcessesLeft = false
    while true {
        let now = clock.now
        let isRunning = process.isRunning
        if ending == .exited {
            if streams[0].hasPassedLimit {
                // Reported even when the child has already exited: what it
                // wrote is still over the cap.
                ending = .outputLimit
            } else if isRunning, stop?.isRequested == true {
                ending = .stopped
            } else if isRunning, let deadline, now >= deadline {
                ending = .timedOut
            }
        }
        // A failed read leaves output that cannot be whole, so the child is
        // ended as for any other reason to stop.
        let isEnding = ending != .exited || streams[0].hasReadFailed
        // A run we end is live while anything of its group is; one that
        // exited on its own leaves what it started alone.
        let isLive = isRunning || (isEnding && process.hasGroupMembersLeft)
        if isLive, isEnding, signaledAt == nil {
            process.send(SIGTERM)
            signaledAt = now
        }
        if isLive, !hasKilled, let signaledAt, now >= signaledAt + timing.terminationGrace {
            process.send(SIGKILL)
            hasKilled = true
        }
        for index in streams.indices {
            streams[index].readAvailable()
        }
        let openFDs = streams.compactMap(\.openFD)
        if isLive, !isRunning, hasKilled, let signaledAt, now >= signaledAt + timing.terminationGrace * 2 {
            // Past SIGKILL and its grace, something of the group is still
            // there: we stop waiting, and say so.
            hasProcessesLeft = true
            break
        }
        if !isLive {
            exitedAt = exitedAt ?? now
            if openFDs.isEmpty || now >= (exitedAt ?? now) + timing.drainGrace {
                break
            }
        }
        if openFDs.isEmpty {
            usleep(useconds_t(timing.pollMilliseconds) * 1000)
        } else {
            var descriptors = openFDs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            _ = poll(&descriptors, nfds_t(descriptors.count), timing.pollMilliseconds)
        }
    }
    // Reaps the child, which has exited by now.
    process.waitUntilExit()
    if ending == .exited, streams[0].hasPassedLimit {
        ending = .outputLimit
    }
    return DrainedOutput(
        stdout: streams[0].bytes,
        stderr: streams[1].bytes,
        ending: ending,
        isStdoutComplete: streams[0].openFD == nil && !streams[0].hasReadFailed,
        hasStdoutReadFailed: streams[0].hasReadFailed,
        hasProcessesLeft: hasProcessesLeft
    )
}

/// One pipe's read end, read without blocking so the loop can end the
/// child or stop reading whatever the writer does.
private struct PipeReader {
    private(set) var bytes = Data()
    /// `nil` once EOF was read, a read failed, or when there was no pipe.
    private(set) var openFD: Int32?
    /// Set once a read fails. The pipe is not read again.
    private(set) var hasReadFailed = false
    /// Set once the pipe held more than `limitBytes`. What comes after is
    /// still read, so the writer is not left blocked, and dropped.
    private(set) var hasPassedLimit = false
    private let limitBytes: Int?
    private var buffer = [UInt8](repeating: 0, count: 16384)

    init(fd: Int32?, limitBytes: Int?) {
        self.limitBytes = limitBytes
        if let fd, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 {
            openFD = fd
        } else {
            openFD = nil
            // A pipe that cannot be read without blocking is not read at all,
            // so nothing of it arrives.
            hasReadFailed = fd != nil
        }
    }

    /// Reads what the pipe holds now, up to EOF.
    mutating func readAvailable() {
        guard let fd = openFD else { return }
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                keep(buffer.prefix(count))
            } else if count == 0 {
                openFD = nil
                return
            } else if errno == EINTR {
                continue
            } else {
                // EAGAIN: nothing more for now. Anything else: the pipe is
                // unusable, and reading it again would not change that.
                if errno != EAGAIN {
                    openFD = nil
                    hasReadFailed = true
                }
                return
            }
        }
    }

    private mutating func keep(_ chunk: ArraySlice<UInt8>) {
        guard !hasPassedLimit else { return }
        if let limitBytes, chunk.count > max(0, limitBytes) - bytes.count {
            hasPassedLimit = true
            return
        }
        bytes.append(contentsOf: chunk)
    }
}
