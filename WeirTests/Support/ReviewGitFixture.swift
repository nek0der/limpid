// ReviewGitFixture.swift
// Weir — Git commands for the review suites' repositories, apart from the developer's configuration.

import Foundation
import Testing
@testable import Weir

enum ReviewGitFixture {
    /// We isolate repository identity and configuration without changing the developer's environment.
    static func run(
        _ arguments: [String],
        cwd: URL
    ) async throws -> GitResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["git"] + arguments
                    process.currentDirectoryURL = cwd
                    var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                    environment["GIT_CONFIG_NOSYSTEM"] = "1"
                    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
                    environment["LC_ALL"] = "C"
                    process.environment = environment
                    process.standardInput = FileHandle.nullDevice
                    let stdout = Pipe.forChildProcess()
                    let stderr = Pipe.forChildProcess()
                    process.standardOutput = stdout
                    process.standardError = stderr
                    try process.run()
                    let output = drainAndWait(process, stdout: stdout, stderr: stderr)
                    return GitResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: output.stdout, encoding: .utf8) ?? "",
                        stderr: String(data: output.stderr, encoding: .utf8) ?? ""
                    )
                })
            }
        }
    }

    /// `run`, for a command the fixture cannot go on without.
    @discardableResult
    static func checked(
        _ arguments: [String],
        cwd: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> GitResult {
        let result = try await run(arguments, cwd: cwd)
        try #require(
            result.succeeded,
            "Git fixture command failed: \(arguments.joined(separator: " ")): \(result.stderr)",
            sourceLocation: sourceLocation
        )
        return result
    }
}
