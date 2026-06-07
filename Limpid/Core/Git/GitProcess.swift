// GitProcess.swift
// Limpid — thin async wrapper around the system `git` CLI. We shell
// out rather than linking libgit2 because:
//   1. The user already has git installed and configured (creds,
//      hooks, signing). We benefit from the same behavior.
//   2. The surface we need (`git worktree list`, `git status`,
//      `git worktree add`) is small and stable.
//   3. Avoids a heavy native dependency on a still-evolving build.
//
// All calls run on a background queue and return a Sendable result.

import Foundation
import OSLog

private let log = Logger.limpid("git.process")

struct GitResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool {
        exitCode == 0
    }
}

enum GitProcessError: Error, LocalizedError {
    case launchFailed(String)
    /// `git` exited with a non-zero status. `result.stderr` is
    /// included as a hint.
    case nonZeroExit(GitResult)

    /// User-facing description. Without `LocalizedError`, the alert
    /// host would read `error.localizedDescription` and get the
    /// `String(describing:)` synthesis (`"GitProcessError(launchFailed:
    /// posix_spawn failed: …)"`) — readable to a maintainer, opaque
    /// to a user. `CreateWorktreeError` / `DeleteWorktreeError`
    /// already conform; bring this enum into the same posture so the
    /// existing alert call sites pick up the localized strings
    /// without any downstream changes.
    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            String(
                localized: "Could not launch git: \(message). Is git installed?",
                comment: "Worktree-operation error — git binary failed to launch"
            )
        case let .nonZeroExit(result):
            result.stderr.isEmpty
                ? String(
                    localized: "git exited with code \(result.exitCode).",
                    comment: "Worktree-operation error — git exited with non-zero code (no stderr)"
                )
                : result.stderr
        }
    }
}

enum GitProcess {
    /// Run `git <args>` with cwd = `cwd`. Throws when the launch
    /// itself fails; non-zero exit codes are returned in `GitResult`
    /// (callers usually treat them as data, e.g. "not a git repo").
    static func run(_ args: [String], cwd: URL) async throws -> GitResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try runSync(args, cwd: cwd)
                    cont.resume(returning: result)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous variant — only call from a background queue.
    static func runSync(_ args: [String], cwd: URL) throws -> GitResult {
        let process = Process()
        // `/usr/bin/env git` picks up whichever git is on PATH, so
        // Homebrew installs (/opt/homebrew/bin/git) work alongside
        // the Xcode-bundled one without us hard-coding either.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = cwd
        // Pin git's locale to the C locale so error messages we
        // pattern-match on (e.g. "not a working tree" in
        // `deleteGitWorktree`) stay in English regardless of the
        // user's LANG / LC_MESSAGES. We inherit the rest of the
        // environment so PATH and user-config locations work.
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw GitProcessError.launchFailed(error.localizedDescription)
        }

        // Drain stdout / stderr concurrently with `waitUntilExit()`.
        // macOS pipe buffers are bounded (~16-64 KB); when `git`
        // writes more than that — `git status --porcelain=v2`
        // against a dirty repo with hundreds of untracked files is
        // the realistic case — its next `write(2)` blocks waiting
        // for the pipe to drain. If we read the pipes only AFTER
        // `waitUntilExit()` returns, nothing drains them, git never
        // exits, and the calling Task parks forever (cancellation
        // doesn't help because `withCheckedThrowingContinuation`
        // can't tear down a running runSync). Two background reads
        // keep both descriptors moving until EOF.
        let outQueue = DispatchQueue(label: "dev.limpid.git.process.stdout")
        let errQueue = DispatchQueue(label: "dev.limpid.git.process.stderr")
        nonisolated(unsafe) var outBuffer = Data()
        nonisolated(unsafe) var errBuffer = Data()
        let outGroup = DispatchGroup()
        let errGroup = DispatchGroup()
        outGroup.enter()
        outQueue.async {
            outBuffer = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outGroup.leave()
        }
        errGroup.enter()
        errQueue.async {
            errBuffer = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            errGroup.leave()
        }
        process.waitUntilExit()
        outGroup.wait()
        errGroup.wait()

        let result = GitResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outBuffer, encoding: .utf8) ?? "",
            stderr: String(data: errBuffer, encoding: .utf8) ?? ""
        )
        if !result.succeeded {
            log
                .debug(
                    """
                    git \(args.joined(separator: " "), privacy: .public) \
                    exited \(result.exitCode, privacy: .public): \
                    \(result.stderr, privacy: .public)
                    """
                )
        }
        return result
    }

    /// List local branch names ("main", "feat-x", …) for the repo.
    static func listLocalBranches(repoRoot: URL) async throws -> [String] {
        let result = try await run(
            ["branch", "--format=%(refname:short)"],
            cwd: repoRoot
        )
        guard result.succeeded else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Current branch name, or nil when HEAD is detached.
    static func currentBranch(repoRoot: URL) async throws -> String? {
        let result = try await run(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            cwd: repoRoot
        )
        guard result.succeeded else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty || name == "HEAD") ? nil : name
    }

    /// Create a new worktree. When `newBranchName` is non-nil, runs
    /// `git worktree add -b <new> <path> <base>`, otherwise checks out
    /// the existing branch.
    @discardableResult
    static func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String? = nil
    ) async throws -> GitResult {
        var args = ["worktree", "add"]
        if let name = newBranchName, !name.isEmpty {
            args.append(contentsOf: ["-b", name])
        }
        // `--` forces git to parse the remaining tokens as positional
        // args. Defends against pathological paths or branch names that
        // start with `-` (git refname rules forbid them, but the
        // separator costs nothing and removes a class of CLI parsing
        // surprises).
        args.append("--")
        args.append(path.path)
        args.append(baseBranch)
        return try await run(args, cwd: repoRoot)
    }

    /// Remove a worktree on disk. Wraps `git worktree remove`.
    /// `force` adds `--force` so dirty / locked worktrees can be
    /// removed too — callers should confirm with the user first since
    /// uncommitted changes are lost.
    @discardableResult
    static func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        return try await run(args, cwd: repoRoot)
    }

    /// If `url` is a linked worktree of a larger git repo, return
    /// the main checkout's working-tree root. Used at "Add Project"
    /// time so the Project's `rootURL` doesn't end up listed inside
    /// its own `git worktree list` output — a self-reference that
    /// confused both the sidebar's worktree rows and any container column logic
    /// that compares container paths.
    ///
    /// Non-git folders, main checkouts, bare repos, arbitrary
    /// subdirectories under any working tree, and lookup failures
    /// all fall through to `url` unchanged. Promotion only triggers
    /// when the user pointed at an *exact* linked-worktree root —
    /// staying anchored at `/repo/subdir` (where the user explicitly
    /// picked a deeper anchor) is intentional.
    static func resolveMainCheckout(of url: URL) async -> URL {
        guard let worktrees = try? await GitWorktreeList.fetch(repoRoot: url),
              let main = worktrees.first,
              !main.isBare
        else { return url }
        let standardized = url.standardizedFileURL
        let isLinked = worktrees.dropFirst().contains {
            $0.path.standardizedFileURL == standardized
        }
        return isLinked ? main.path.standardizedFileURL : url
    }

    /// Quick check: does `git` find a repository rooted at `url`?
    /// Returns false for non-git folders and on launch errors.
    static func isGitRepository(_ url: URL) async -> Bool {
        // `git -C <url> rev-parse --is-inside-work-tree` exits 0 only
        // when inside a working tree. Using `--git-dir` instead would
        // be wrong — submodules and bare repos would answer "yes" to
        // the existence check but aren't usable as Limpid roots.
        guard let result = try? await run(
            ["-C", url.path, "rev-parse", "--is-inside-work-tree"],
            cwd: url
        ) else { return false }
        return result.succeeded
            && result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }
}
