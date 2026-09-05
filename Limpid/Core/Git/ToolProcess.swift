// ToolProcess.swift
// Limpid — locating and running optional developer CLIs (`gh`, `glab`).
//
// Separate from `GitProcess` because these tools are *optional*.
// `git` sits in `/usr/bin`, which is on launchd's PATH, so resolving
// it by name always works; `gh` and `glab` live wherever the user's
// package manager put them. A GUI app
// launched from Finder or the Dock inherits launchd's PATH
// (`/usr/bin:/bin:/usr/sbin:/sbin`), which contains neither Homebrew's
// `/opt/homebrew/bin` nor `~/.local/bin` — so resolving `gh` by name
// finds nothing and the feature silently disables itself. `ToolLocator`
// resolves an absolute path once per process so the Finder-launch and
// terminal-launch cases behave identically.
//
// The spawn helper also gives us a timeout that actually fires.
// Wrapping a `Process` in `withCheckedContinuation` alone is
// not cancellable: `withTaskGroup` waits for every child before
// returning, and `cancelAll()` only sets a flag the continuation never
// observes, so a hung child would pin the caller indefinitely. We
// install a cancellation handler that terminates the child, which
// unblocks `waitUntilExit()` and lets the group finish promptly.

import Foundation
import OSLog

private let log = Logger.limpid("git.tool")

/// One-shot result of an external tool invocation.
struct ToolResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

// MARK: - Locating

/// Resolves optional CLI tools to absolute paths, caching the answer
/// for its own lifetime. Installing a tool mid-session requires a
/// Limpid restart to pick up — an acceptable trade for never paying
/// the lookup twice.
///
/// An `actor` rather than the codebase's usual `@MainActor final
/// class` because every caller is already off the main actor: the
/// syncer fetches from a background task, and routing a cache read
/// through MainActor would hop twice per lookup for state the UI
/// never reads. The cache is the only thing that needs serializing.
actor ToolLocator {

    /// Absent key means "not looked up yet"; a present `nil` value
    /// means "looked up and genuinely not installed". Collapsing those
    /// two into one optional would re-run the login-shell probe on
    /// every tick for users who don't have the tool.
    private var cache: [String: URL?] = [:]

    /// Directories we check before falling back to a login shell.
    /// These cover the overwhelming majority of installs and cost only
    /// a `stat` each, whereas the shell fallback sources the user's
    /// startup files.
    private static let wellKnownDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin"
    ]

    func locate(_ name: String) async -> URL? {
        if let cached = cache[name] {
            return cached
        }
        let resolved = await Self.resolve(name)
        cache[name] = resolved
        if let resolved {
            log.debug("resolved \(name, privacy: .public) at \(resolved.path, privacy: .private)")
        } else {
            log.debug("could not resolve \(name, privacy: .public)")
        }
        return resolved
    }

    /// Three escalating strategies, cheapest first. We stop at the
    /// first hit.
    private static func resolve(_ name: String) async -> URL? {
        // Guard the name even though every call site passes a literal:
        // it flows into a shell command below, and a compile-time
        // constant today can become a config value tomorrow.
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "-" }) else { return nil }
        if let hit = searchInheritedPath(name) {
            return hit
        }
        if let hit = searchWellKnownDirectories(name) {
            return hit
        }
        return await searchLoginShell(name)
    }

    /// Walk `PATH` as this process inherited it. Costs no subprocess
    /// and succeeds whenever Limpid was launched from a shell.
    private static func searchInheritedPath(_ name: String) -> URL? {
        searchPathVariable(ProcessInfo.processInfo.environment["PATH"] ?? "", for: name)
    }

    /// Split out from `searchInheritedPath` so tests can drive it with
    /// a constructed `PATH` instead of the one this process happens to
    /// have inherited — the Finder-launch case we are guarding against
    /// is precisely a `PATH` the test runner never sees.
    static func searchPathVariable(_ path: String, for name: String) -> URL? {
        firstExecutable(named: name, in: path.split(separator: ":").map(String.init))
    }

    private static func searchWellKnownDirectories(_ name: String) -> URL? {
        firstExecutable(named: name, in: wellKnownDirectories)
    }

    /// Internal so tests can pin the "first match wins, non-executables
    /// are skipped" contract that both search tiers rely on.
    static func firstExecutable(named name: String, in directories: [String]) -> URL? {
        let fm = FileManager.default
        for directory in directories where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// Last resort: ask the user's login shell, which picks up PATH
    /// entries a tool put somewhere we would not think to look.
    ///
    /// `-lc` is login but not interactive, so this reads `.zprofile`
    /// and not `.zshrc`. That is the wrong half for the version
    /// managers whose install instructions say to activate in
    /// `.zshrc` (mise and asdf both do), and there is no good way to
    /// have both: sourcing `.zshrc` means running a user's
    /// interactive setup — prompts, completions, whatever else — to
    /// answer "where is `gh`". We pay one shell startup per tool per
    /// process for the half we do get.
    private static func searchLoginShell(_ name: String) async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let result = await runTool(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v \(name)"],
            workingDirectory: nil,
            environment: [:],
            timeout: .seconds(5)
        )
        guard let result, result.isSuccess else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
}

// MARK: - Running

/// Run `executable` with `arguments`. Returns `nil` when the process
/// could not be launched or exceeded `timeout` — callers in this
/// subsystem treat every failure the same way ("show nothing"), so a
/// typed error would only be unwrapped and discarded.
///
/// `environment` entries are layered on top of the inherited
/// environment rather than replacing it, so the child keeps the
/// user's `HOME`, credential helpers, and proxy settings.
func runTool(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String] = [:],
    timeout: Duration
) async -> ToolResult? {
    await withTaskGroup(of: ToolResult??.self) { group in
        group.addTask {
            await spawn(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment
            )
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            // A timed-out run and a run that never launched are both
            // "no result" to every caller here. The extra optional
            // exists only so `group.next()` can tell "a task finished"
            // from "the group is empty".
            return ToolResult??.some(nil)
        }
        let first = await group.next() ?? nil
        // Terminating the child (via the spawn task's cancellation
        // handler) is what lets this group return promptly instead of
        // blocking on `waitUntilExit()`.
        group.cancelAll()
        return first ?? nil
    }
}

/// Holds the child process so a cancellation handler running on
/// another task can terminate it. `NSLock` rather than an actor
/// because the handler is synchronous and must not suspend.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var isCancelled = false

    /// Returns false when cancellation already arrived, in which case
    /// the caller must not start the process at all.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.process = process
        return true
    }

    /// Call once `run()` has returned.
    ///
    /// `terminate()` can't signal a process that hasn't launched —
    /// `Process.terminate()` raises on one — so a cancellation landing
    /// between `adopt` and `run` sets the flag and finds nothing to
    /// kill, and `adopt` has already returned by then. Re-checking here
    /// closes that window. It matters because `runTool` awaits every
    /// child of its task group: an unkilled child means the timeout
    /// does not hold and the call blocks until the tool exits on its
    /// own.
    func launched() {
        lock.lock()
        let cancelled = isCancelled
        let target = process
        lock.unlock()
        guard cancelled, let target, target.isRunning else { return }
        target.terminate()
    }

    func terminate() {
        lock.lock()
        let target = process
        isCancelled = true
        lock.unlock()
        guard let target, target.isRunning else { return }
        target.terminate()
    }
}

private func spawn(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String]
) async -> ToolResult? {
    let box = ProcessBox()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                if let workingDirectory {
                    process.currentDirectoryURL = workingDirectory
                }

                var env = ProcessInfo.processInfo.environment
                // C locale so the tool's human-readable strings stay
                // reproducible regardless of the user's region.
                env["LC_ALL"] = "C"
                env["LANG"] = "C"
                for (key, value) in environment {
                    env[key] = value
                }
                process.environment = env

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                guard box.adopt(process) else {
                    cont.resume(returning: nil)
                    return
                }
                do {
                    try process.run()
                } catch {
                    log.debug("launch failed: \(String(describing: error), privacy: .public)")
                    cont.resume(returning: nil)
                    return
                }
                box.launched()

                let output = drainAndWait(process, stdout: stdoutPipe, stderr: stderrPipe)

                cont.resume(returning: ToolResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                    stderr: String(data: output.stderr, encoding: .utf8) ?? ""
                ))
            }
        }
    } onCancel: {
        box.terminate()
    }
}
