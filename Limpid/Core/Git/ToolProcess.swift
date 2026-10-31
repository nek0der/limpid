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
// The run helper also gives us a timeout that actually fires.
// Wrapping a `Process` in `withCheckedContinuation` alone is not
// cancellable, and SIGTERM alone does not end a child that ignores it
// or a pipe that something the child started still holds. The wait
// itself (`drainAndWait`) carries the timeout and the cancellation, so
// it ends the child and stops reading in every one of those cases.

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
            readsOutputFromFile: true,
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
/// could not be launched, was canceled, or exceeded `timeout` —
/// callers in this subsystem treat every failure the same way ("show
/// nothing"), so a typed error would only be unwrapped and discarded.
/// The timeout holds whatever the child does: one that ignores SIGTERM
/// is killed, and one that leaves something behind holding its output
/// is not waited for (`drainAndWait`).
///
/// `environment` entries are layered on top of the inherited
/// environment rather than replacing it, so the child keeps the
/// user's `HOME`, credential helpers, and proxy settings.
///
/// `readsOutputFromFile` sends stdout to a temporary file and stderr to
/// the null device, for a login shell: what its profile starts in the
/// background inherits the shell's output, and with a pipe that process
/// would be cut off (SIGPIPE) the moment we stop reading. It can write to
/// a file for as long as it likes. `stderr` is then empty.
func runTool(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String] = [:],
    readsOutputFromFile: Bool = false,
    timeout: Duration
) async -> ToolResult? {
    let stop = ProcessStopRequest()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: runToolSync(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    environment: environment,
                    readsOutputFromFile: readsOutputFromFile,
                    timeout: timeout,
                    stop: stop
                ))
            }
        }
    } onCancel: {
        stop.request()
    }
}

// swiftlint:disable:next function_parameter_count
private func runToolSync(
    executable: URL,
    arguments: [String],
    workingDirectory: URL?,
    environment: [String: String],
    readsOutputFromFile: Bool,
    timeout: Duration,
    stop: ProcessStopRequest
) -> ToolResult? {
    // Canceled before it started: nothing to launch. One canceled
    // after this check is ended by `drainAndWait`.
    guard !stop.isRequested else { return nil }
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

    let stdoutPipe: Pipe?
    let stderrPipe: Pipe?
    let outputFile: ToolOutputFile?
    if readsOutputFromFile {
        guard let file = ToolOutputFile() else { return nil }
        outputFile = file
        stdoutPipe = nil
        stderrPipe = nil
        process.standardOutput = file.handle
        process.standardError = FileHandle.nullDevice
    } else {
        outputFile = nil
        let out = Pipe.forChildProcess()
        let err = Pipe.forChildProcess()
        stdoutPipe = out
        stderrPipe = err
        process.standardOutput = out
        process.standardError = err
    }
    defer { outputFile?.remove() }

    do {
        try process.run()
    } catch {
        log.debug("launch failed: \(String(describing: error), privacy: .private)")
        return nil
    }

    let output = drainAndWait(process, stdout: stdoutPipe, stderr: stderrPipe, timeout: timeout, stop: stop)
    guard output.ending == .exited else { return nil }
    let stdout = outputFile?.contents() ?? output.stdout
    return ToolResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdout, encoding: .utf8) ?? "",
        stderr: String(data: output.stderr, encoding: .utf8) ?? ""
    )
}

/// A user-only temporary file a child writes its stdout to.
private final class ToolOutputFile {
    let url: URL
    let handle: FileHandle

    init?() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("limpid-tool-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: url)
        else {
            log.debug("could not create a file for a tool's output")
            return nil
        }
        self.url = url
        self.handle = handle
    }

    /// What the child wrote. Read once it has exited; a process it left
    /// behind may still write, and what comes later is not ours.
    func contents() -> Data {
        (try? Data(contentsOf: url)) ?? Data()
    }

    func remove() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }
}
