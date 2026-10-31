// WorktreeSetup.swift
// Weir — runs a project's bootstrap commands in a new worktree, in order, stopping at the first that fails.

import Foundation
import OSLog

private let log = Logger.weir("session.worktree")

/// The setup stage of a new session: the project's bootstrap commands
/// ("Setup Commands" in its settings), each through `sh -c` in the
/// worktree so a step can be a pipeline (`pnpm install && pnpm db:reset`).
///
/// It stops at the first step that fails: the ones after it may need what
/// it was to make, and the failed step is what the person retries.
/// The hook that bootstraps a worktree an agent adds with `git worktree
/// add` goes on past a failure instead (`rust/weir-agent-hook/src/
/// worktree.rs`): nothing there can report a stage or offer a retry, so
/// doing what it can is the better of the two there.
enum WorktreeSetup {
    /// Why a step failed.
    enum FailureReason: Equatable, Sendable {
        /// It exited non-zero or did not start: the end of what it
        /// printed, or why it did not start.
        case exited(logTail: String)
        /// Its `cwd` leads out of the worktree; it was not run.
        case directoryOutsideWorktree(String)
    }

    /// The step that failed: its place among the steps run, its command,
    /// and why.
    struct Failure: Equatable, Sendable {
        let offset: Int
        let command: String
        let reason: FailureReason
    }

    /// What one step printed, kept to its end.
    static let logTailBytes = 8 * 1024

    /// Runs `items` in `worktree`, in order, with the `PATH` of the
    /// person's shell (`LoginShellPath`). `nil` when every step ran.
    /// Canceling the waiting task stops the step that runs and throws
    /// `CancellationError`, which is neither a success nor a failed step.
    static func run(_ items: [BootstrapItem], in worktree: URL) async throws -> Failure? {
        try await run(items, in: worktree, path: LoginShellPath.shared.path())
    }

    /// Where a step's `PATH` comes from; a test gives its own rather than
    /// start the person's login shell. Throws `CancellationError` when the
    /// waiting task is canceled.
    typealias PathSource = @Sendable () async throws -> String?

    static let loginShellPath: PathSource = { try await LoginShellPath.shared.path() }

    /// `run` with the `PATH` given: `nil` keeps the app's own. `onStep` is
    /// told the offset of each step as it starts, for the stage to show
    /// which one runs.
    static func run(
        _ items: [BootstrapItem],
        in worktree: URL,
        path: String?,
        steps: RunningSteps = RunningSteps(),
        onStep: @Sendable (Int) async -> Void = { _ in }
    ) async throws -> Failure? {
        for (offset, item) in items.enumerated() {
            try Task.checkCancellation()
            await onStep(offset)
            // `appendingPathComponent` doesn't resolve `..` and
            // `chdir(2)` would happily follow it, so a careless
            // `cwd: "../../"` could land the step in the project root. The
            // Rust and legacy hook receivers apply the same guard.
            if let cwd = item.cwd, isUnsafeRelativePath(cwd) {
                log.warning("bootstrap step not run — cwd '\(cwd, privacy: .private)' escapes the worktree")
                return Failure(offset: offset, command: item.cmd, reason: .directoryOutsideWorktree(cwd))
            }
            let directory: URL
            switch stepDirectory(item.cwd, in: worktree) {
            case let .inside(resolved):
                directory = resolved
            case let .outside(cwd, resolved):
                log.warning("bootstrap step not run — cwd resolves to '\(resolved, privacy: .private)' outside the worktree")
                return Failure(offset: offset, command: item.cmd, reason: .directoryOutsideWorktree(cwd))
            case let .unresolved(reason):
                log.warning("bootstrap step not run — \(reason, privacy: .private)")
                return Failure(offset: offset, command: item.cmd, reason: .exited(logTail: reason))
            }
            let logTail = await runStep(item, at: directory, path: path, steps: steps)
            // A step stopped by the cancel exits non-zero; that is not its
            // failure.
            try Task.checkCancellation()
            if let logTail {
                return Failure(offset: offset, command: item.cmd, reason: .exited(logTail: logTail))
            }
        }
        return nil
    }

    /// The process groups of the steps one owner has running, for that
    /// owner to stop when Weir quits. `SessionLaunchStore` keeps its own.
    /// One list shared by every run let a quit stop steps it never started:
    /// two stores in one process, as tests running side by side have,
    /// killed each other's steps. A run given no list keeps its steps to
    /// itself (`run`'s default).
    final class RunningSteps: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: Set<pid_t> = []

        func insert(_ group: pid_t) {
            _ = lock.withLock { groups.insert(group) }
        }

        func remove(_ group: pid_t) {
            _ = lock.withLock { groups.remove(group) }
        }

        /// Stops every step on the list, before Weir exits: each group
        /// gets SIGTERM, a moment to end (`quitGrace`), and SIGKILL if
        /// anything of it is left. Synchronous, as it runs inside
        /// `willTerminate`: the SIGKILL a cancel schedules
        /// (`RunningStep.stop`) comes seconds later, after the process that
        /// would send it is gone, and a step that ignores SIGTERM would go on
        /// in a worktree no one watches.
        func stopBeforeExit() {
            let groups = lock.withLock { self.groups }
            guard !groups.isEmpty else { return }
            for group in groups {
                kill(-group, SIGTERM)
            }
            let deadline = ContinuousClock.now + WorktreeSetup.quitGrace
            while groups.contains(where: isRunning(group:)), ContinuousClock.now < deadline {
                usleep(20000)
            }
            for group in groups where isRunning(group: group) {
                kill(-group, SIGKILL)
            }
        }
    }

    /// How long a quit lets the steps end after SIGTERM: as long as the
    /// other waits at quit, short enough that a quit still feels immediate.
    static let quitGrace: Duration = .milliseconds(500)

    /// Whether any process of the group is left that has not exited.
    static func isRunning(group: pid_t) -> Bool {
        ProcessLiveness.hasLiveMembers(group: group)
    }

    /// Waits for the last process of a stopped step's group: the setup
    /// counts as stopped only once nothing it started still runs in the
    /// folder. The wait sends the group SIGKILL itself `killAfter` into the
    /// wait, and gives up only `killGrace` after that. Left to the timer of
    /// `RunningStep.stop` alone, the SIGKILL could come after a fixed
    /// deadline here on a busy Mac, and a child that ignored SIGTERM would
    /// still be running when the setup was reported stopped. A second
    /// SIGKILL costs nothing, and the group's id is still ours while a
    /// member is left. On `SuspendingClock`, which stands still while the
    /// Mac sleeps, as the `DispatchTime` of that timer does.
    static func waitForGroup(_ group: pid_t) async {
        let clock = SuspendingClock()
        let killAt = clock.now + killAfter
        var killedAt: SuspendingClock.Instant?
        while isRunning(group: group) {
            let now = clock.now
            if let killedAt {
                if now >= killedAt + killGrace {
                    log.fault("a setup step's process group outlived SIGKILL")
                    return
                }
            } else if now >= killAt {
                kill(-group, SIGKILL)
                killedAt = now
            }
            // Not `Task.sleep`: the task waiting here is the canceled one,
            // whose sleep would return at once.
            await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(50)) {
                    resumed.resume()
                }
            }
        }
    }

    /// How long a step has to end after SIGTERM before SIGKILL.
    fileprivate static let killAfter: Duration = .seconds(3)

    /// How long a group sent SIGKILL is waited for.
    private static let killGrace: Duration = .seconds(2)

    private static func isUnsafeRelativePath(_ path: String) -> Bool {
        path.isEmpty
            || path.hasPrefix("/")
            || path.hasPrefix("../")
            || path.contains("/../")
            || path.hasSuffix("/..")
            || path == ".."
    }

    /// Where a step's folder really is, symlinks resolved.
    enum StepDirectory: Equatable {
        /// The folder's real path, inside the worktree's.
        case inside(URL)
        /// The step's `cwd`, whose real path (the second) is not inside
        /// the worktree's. Only a `cwd` can lead out: the worktree itself is
        /// inside by definition.
        case outside(cwd: String, resolved: String)
        /// Why the worktree or the folder has no real path: it does not
        /// exist, or a link in it leads nowhere.
        case unresolved(String)
    }

    /// The real path of the step's folder, checked to lie inside the real
    /// path of the worktree, just before the step runs. The string check
    /// above cannot see a link: the branch just checked out decides what
    /// the worktree holds, and a `frontend` there that is a symlink to
    /// another project, or a `packages` link that `cwd: "packages/web"`
    /// passes through, would run the person's own command in that other
    /// project. `realpath(3)` resolves a link in any component. The Rust
    /// hook (`run_bootstrap`) makes the same check.
    ///
    /// The step is started in the resolved path, so `chdir(2)` follows no
    /// link this check did not see. What is left is a component of that
    /// path being swapped for a link between this check and the start.
    /// We leave that open rather than start from a directory descriptor
    /// (`posix_spawn_file_actions_addfchdir_np`, in place of `Process`):
    /// whatever could make that swap in the window is already running in
    /// the person's account in the worktree (an earlier step, or code it
    /// started), with no boundary left for a descriptor to keep. The check
    /// guards against what the branch holds when the step is about to
    /// start, which is what the branch alone decides.
    ///
    /// It guards the folder a step starts in, not what the step does
    /// there: a `node_modules` link in the branch still takes `pnpm
    /// install`'s writes wherever it leads, as it would in any checkout.
    static func stepDirectory(_ cwd: String?, in worktree: URL) -> StepDirectory {
        let root: String
        switch realPath(worktree.path) {
        case let .success(resolved): root = resolved
        case let .failure(failure): return .unresolved(failure.reason)
        }
        guard let cwd else { return .inside(URL(fileURLWithPath: root, isDirectory: true)) }
        let folder: String
        switch realPath(worktree.appendingPathComponent(cwd).path) {
        case let .success(resolved): folder = resolved
        case let .failure(failure): return .unresolved(failure.reason)
        }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard folder == root || folder.hasPrefix(prefix) else { return .outside(cwd: cwd, resolved: folder) }
        return .inside(URL(fileURLWithPath: folder, isDirectory: true))
    }

    /// `realpath(3)`, or why it failed.
    private static func realPath(_ path: String) -> Result<String, RealPathFailure> {
        guard let resolved = realpath(path, nil) else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            return .failure(RealPathFailure(reason: "\(path): \(POSIXError(code).localizedDescription)"))
        }
        defer { free(resolved) }
        return .success(String(cString: resolved))
    }

    /// Why a path has no real path, as the step's log would say it.
    private struct RealPathFailure: Error {
        let reason: String
    }

    /// Runs one step and waits for it. `nil` when it exited 0, else the
    /// end of what it printed, or why it did not start.
    ///
    /// Its output goes to a file rather than a pipe: a pipe left unread
    /// stops a chatty `pnpm install` once its buffer fills, and a daemon
    /// the step leaves running would keep a pipe open past the step.
    ///
    /// NOTE: `item.timeout` is still not enforced, as in the hook
    /// backends, which must change with it so the path a worktree was made
    /// by cannot change what its setup does. A step that hangs holds the
    /// setup until the task waiting for it is canceled.
    private static func runStep(_ item: BootstrapItem, at directory: URL, path: String?, steps: RunningSteps) async -> String? {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("weir-setup-\(UUID().uuidString).log")
        // Without a file the step still runs; only its words are lost.
        let output = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            ? (try? FileHandle(forWritingTo: logURL)) : nil
        defer {
            try? output?.close()
            try? FileManager.default.removeItem(at: logURL)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", item.cmd]
        process.currentDirectoryURL = directory
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = output ?? FileHandle.nullDevice
        if let path {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
        }
        let running = RunningStep(steps: steps)
        let outcome: StepOutcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<StepOutcome, Never>) in
                process.terminationHandler = { proc in
                    running.resume(cont, with: .exited(proc.terminationStatus))
                }
                guard running.adopt(process) else {
                    running.resume(cont, with: .cancelled)
                    return
                }
                do {
                    try process.run()
                    running.launched()
                } catch {
                    log.warning("""
                    bootstrap step failed to launch: \(item.cmd, privacy: .private) \
                    — \(error.localizedDescription, privacy: .private)
                    """)
                    running.resume(cont, with: .notStarted(error.localizedDescription))
                }
            }
        } onCancel: {
            running.terminate()
        }
        if Task.isCancelled, process.processIdentifier > 0 {
            await waitForGroup(process.processIdentifier)
        }
        // Past here the step is no quit's to stop: it ended, or what it
        // left behind is what a step that ends leaves anyway.
        running.finished()
        switch outcome {
        case .exited(0), .cancelled:
            return nil
        case let .exited(status):
            if !Task.isCancelled {
                log.warning("bootstrap step exited \(status, privacy: .public): \(item.cmd, privacy: .private)")
            }
            return tail(of: logURL)
        case let .notStarted(reason):
            return reason
        }
    }

    /// The last `logTailBytes` of the file, from the first whole character.
    static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(logTailBytes) ? size - UInt64(logTailBytes) : 0)
        return tail(of: (try? handle.readToEnd()) ?? Data())
    }

    /// The last `logTailBytes` of `data`, read as text from the first
    /// whole character: what a log and git's own words keep.
    static func tail(of data: Data) -> String {
        var data = data.suffix(logTailBytes)
        // Cut inside a UTF-8 character: drop its continuation bytes.
        while let first = data.first, first & 0xC0 == 0x80 {
            data.removeFirst()
        }
        // Lenient: one byte that is not UTF-8 (a tool writing Latin-1, a
        // stray binary) must not lose the whole log.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// How a step ended.
private enum StepOutcome: Sendable {
    case exited(Int32)
    case notStarted(String)
    case cancelled
}

/// The step's process, for the cancellation handler on another thread,
/// and the one resume of its continuation. A lock rather than an actor:
/// the handler is synchronous and must not suspend.
private final class RunningStep: @unchecked Sendable {
    /// The list of the run's owner, for its quit to stop this step
    /// (`WorktreeSetup.RunningSteps.stopBeforeExit`).
    private let steps: WorktreeSetup.RunningSteps

    init(steps: WorktreeSetup.RunningSteps) {
        self.steps = steps
    }

    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false
    private var isResumed = false

    /// False when cancellation came first: the process must not start.
    func adopt(_ process: Process) -> Bool {
        lock.withLock {
            guard !isCancelled else { return false }
            self.process = process
            return true
        }
    }

    /// A cancellation between `adopt` and `run` found nothing running to
    /// stop; it is stopped here.
    func launched() {
        let target: Process? = lock.withLock {
            if let process {
                steps.insert(process.processIdentifier)
            }
            return isCancelled ? process : nil
        }
        if let target {
            Self.stop(target)
        }
    }

    /// The step is over, stopped or not: a quit no longer signals its group,
    /// whose id may be another's by then.
    func finished() {
        lock.withLock {
            if let process, process.processIdentifier > 0 {
                steps.remove(process.processIdentifier)
            }
        }
    }

    func terminate() {
        let target: Process? = lock.withLock {
            isCancelled = true
            return process
        }
        if let target {
            Self.stop(target)
        }
    }

    /// `Process` makes the step the leader of its own process group, and
    /// the whole group gets SIGTERM, so the step's children stop with it.
    /// One that ignores SIGTERM (`trap '' TERM`, which children inherit)
    /// would hold the cancel forever, so the group gets SIGKILL after
    /// `killAfter` — whether or not its leader is still there: a shell that
    /// died of the SIGTERM leaves a child that ignored it writing in the
    /// folder. A group's id is not another's while any of its members runs;
    /// once the last is gone, the id comes back only after the kernel's
    /// sequential pids wrap around, far longer than those seconds. A leader
    /// that already ended with children left in its group still has them
    /// stopped.
    private static func stop(_ process: Process) {
        let group = process.processIdentifier
        guard group > 0, process.isRunning || WorktreeSetup.isRunning(group: group) else { return }
        // The leader too, in case it is not the group's: `Process` makes it
        // one, and a step is never started any other way, but signaling it
        // costs nothing.
        if process.isRunning {
            process.terminate()
        }
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(Int(WorktreeSetup.killAfter / .milliseconds(1)))) {
            if WorktreeSetup.isRunning(group: group) {
                kill(-group, SIGKILL)
            }
        }
    }

    func resume(_ cont: CheckedContinuation<StepOutcome, Never>, with value: StepOutcome) {
        let shouldResume = lock.withLock {
            guard !isResumed else { return false }
            isResumed = true
            return true
        }
        if shouldResume {
            cont.resume(returning: value)
        }
    }
}

/// The `PATH` a setup step runs with: the app's own and what the person's
/// login shell adds, the app's first when it was opened from a terminal,
/// the login shell's first when it was opened from the Dock (`merged`).
/// Opened from the Dock, an app has launchd's
/// `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) and would find no `pnpm` or
/// `bundle`, which the hook finds in the agent's shell; opened from a
/// terminal, it has that terminal's, whose order (nvm, mise, a venv) must
/// win over the Homebrew one the login shell puts first. `-lc` reads
/// `.zprofile`, not `.zshrc` (`ToolLocator.searchLoginShell` says why).
/// Read once a launch.
actor LoginShellPath {
    static let shared = LoginShellPath()

    /// What a login shell prints before and after the `PATH`, so that
    /// whatever its profile and logout files print is left out.
    static let marker = "__WEIR_PATH__"

    private var reading: Task<String?, Never>?
    private let read: @Sendable () async -> String?

    /// `read` is the login shell's; a test gives its own.
    init(read: @escaping @Sendable () async -> String? = { await LoginShellPath.readLoginShell() }) {
        self.read = read
    }

    /// The merged `PATH`. A canceled caller stops waiting at once and
    /// throws `CancellationError`; the read itself, up to its five
    /// seconds, goes on for the next caller.
    func path() async throws -> String? {
        let read = read
        let task = reading ?? Task { await read() }
        reading = task
        let wait = LoginShellPathWait()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wait.set(continuation)
                Task { await wait.resume(with: .success(task.value)) }
            }
        } onCancel: {
            wait.resume(with: .failure(CancellationError()))
        }
    }

    private static func readLoginShell() async -> String? {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var login: String?
        if FileManager.default.isExecutableFile(atPath: shell),
           let result = await runTool(
               executable: URL(fileURLWithPath: shell),
               arguments: ["-lc", "printf '\\n\(marker)%s\(marker)\\n' \"$PATH\""],
               workingDirectory: nil,
               readsOutputFromFile: true,
               timeout: .seconds(5)
           ),
           result.isSuccess
        {
            login = loginPath(in: result.stdout)
        }
        return merged(inherited: inherited, login: login)
    }

    /// The `PATH` between the markers, whatever the shell printed around
    /// it.
    static func loginPath(in output: String) -> String? {
        guard let start = output.range(of: marker),
              let end = output.range(of: marker, range: start.upperBound..<output.endIndex)
        else { return nil }
        let path = output[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// launchd's own `PATH`, which an app opened from the Dock has.
    static let launchdDefault: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// The two `PATH`s in one, each entry once. The app's order first, then
    /// what only the login shell has: opened from a terminal, the app has
    /// the person's chosen versions in front. Opened from the Dock, the
    /// app has launchd's `PATH` alone, and the login shell's order goes
    /// first, or `/usr/bin/bundle` and the system's Ruby would win over
    /// Homebrew's and the version managers' shims. Only absolute entries
    /// of the login shell's count: a shell that does not expand `$PATH`
    /// in our command prints it as it is. `nil` when both are empty.
    static func merged(inherited: String, login: String?) -> String? {
        let inheritedEntries = inherited.split(separator: ":").map(String.init)
        let loginEntries = (login ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let isLaunchdDefault = inheritedEntries.allSatisfy(launchdDefault.contains)
        var entries: [String] = []
        var seen: Set<String> = []
        for entry in isLaunchdDefault ? loginEntries + inheritedEntries : inheritedEntries + loginEntries
            where !entry.isEmpty && seen.insert(entry).inserted
        {
            entries.append(entry)
        }
        return entries.isEmpty ? nil : entries.joined(separator: ":")
    }
}

/// The one resume of a wait for the login shell's `PATH`: by the read, or
/// by the cancel, whichever comes first, before or after the continuation
/// is there. A lock rather than an actor: the cancellation handler is
/// synchronous.
private final class LoginShellPathWait: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, any Error>?
    private var early: Result<String?, any Error>?
    private var isResumed = false

    func set(_ continuation: CheckedContinuation<String?, any Error>) {
        let result: Result<String?, any Error>? = lock.withLock {
            guard let early else {
                self.continuation = continuation
                return nil
            }
            isResumed = true
            return early
        }
        if let result {
            continuation.resume(with: result)
        }
    }

    func resume(with result: Result<String?, any Error>) {
        let target: CheckedContinuation<String?, any Error>? = lock.withLock {
            guard !isResumed else { return nil }
            guard let continuation else {
                if early == nil {
                    early = result
                }
                return nil
            }
            isResumed = true
            self.continuation = nil
            return continuation
        }
        target?.resume(with: result)
    }
}
