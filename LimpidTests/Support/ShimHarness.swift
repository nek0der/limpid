// ShimHarness.swift
// Limpid — runs an agent shim from the source tree against stubs that record what it handed on.

import Foundation
import Testing

/// What the shim suites share: where a shim and its settings template are in
/// the source tree, the stub that records its argv, the environment it runs
/// in, and running it directly or under a pty.
///
/// One copy for every shim suite, so each waits for the shim with a deadline
/// and a shim stuck on input fails its test rather than stopping the run.
enum ShimHarness {
    /// The PATH a shim runs with: the system's own folders, so nothing the
    /// developer installed (a real `claude`, a real `tmux`) is found.
    static let systemPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// The shim script for `agent` (`claude`, `codex`) in the source tree.
    static func shim(_ agent: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> URL {
        try root(sourceLocation: sourceLocation).appendingPathComponent("Limpid/Resources/\(agent)-shim/\(agent)")
    }

    /// The Claude settings template. It lives in the provider crate and the
    /// build copies it into the bundle beside the shim; a test runs the shim
    /// from the source tree, where there is no bundle, so it points the shim
    /// at the source instead.
    static func claudeSettingsTemplate(sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try root(sourceLocation: sourceLocation)
            .appendingPathComponent("rust/limpid-provider-claude/resources/settings.template.json").path
    }

    /// The environment every shim run starts from, with `dir` as its home
    /// and temporary folder so nothing it writes lands outside the test's.
    static func environment(in dir: URL) -> [String: String] {
        ["PATH": systemPath, "HOME": dir.path, "TMPDIR": dir.path]
    }

    /// A shell script that records its arguments in `argvFile`, then runs
    /// `then`. NUL-separated, so an argument carrying spaces or newlines (a
    /// settings payload, a `-c` value, a prompt) stays one argument.
    static func argvRecorder(into argvFile: URL, then: String = "exit 0") -> String {
        """
        #!/bin/sh
        : > "\(argvFile.path)"
        for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
        \(then)
        """
    }

    /// Writes `script` to `url` and makes it executable.
    static func writeExecutable(_ script: String, at url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// The arguments an `argvRecorder` stub recorded; nil when it never ran,
    /// since it truncates its file before recording. With
    /// `keepsEmptyArguments`, an empty argument stays in the list.
    static func recordedArgv(_ url: URL, keepsEmptyArguments: Bool = false) -> [String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard keepsEmptyArguments else {
            return text.split(separator: "\0").map(String.init)
        }
        return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
    }

    /// Runs `shim` with `arguments` and waits for it, at most ten seconds.
    ///
    /// `underPTY` runs it through `script`, so its stdin and stdout are a
    /// terminal: the tmux hosting decision asks whether they are. Without
    /// it they are the null device, so only a pty reaches that branch.
    @discardableResult
    static func run(
        _ shim: URL,
        _ arguments: [String],
        environment: [String: String],
        underPTY: Bool = false,
        currentDirectory: URL? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Process {
        let process = Process()
        if underPTY {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", "/bin/sh", shim.path] + arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + arguments
            // Left alone, the shim inherits the test runner's, which are a
            // terminal when the run was started from one, and the hosting
            // branch would be reached after all.
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
        }
        process.environment = environment
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        try process.run()
        #expect(process.waitUntilExit(within: 10), "the shim did not exit within ten seconds", sourceLocation: sourceLocation)
        return process
    }

    private static func root(sourceLocation: SourceLocation) throws -> URL {
        try #require(RepoFixture.limpidRoot, sourceLocation: sourceLocation)
    }
}
