// GitRunning.swift
// Limpid — narrow protocol over the GitProcess operations the worktree CRUD
// pipeline calls. Letting WorkspaceSession+Worktree take an injectable
// `any GitRunning` lets the unit tests script success / failure cases
// without shelling out to a real `git`, which is what unlocks
// coverage on the 400+ LOC of worktree mutation logic.
//
// The production implementation is `LiveGit`, which simply forwards
// to the existing static methods on `GitProcess`. The test target
// supplies `FakeGit` (in LimpidTests/Support/) that returns whatever
// `GitResult` was scripted for the case under test.

import Foundation

protocol GitRunning: Sendable {
    func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String?
    ) async throws -> GitResult

    func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult

    /// `git branch <name> <startPoint>`: the new branch on its own, before
    /// the worktree is added on it, so a failure says which of the two
    /// did not happen.
    func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult

    /// `git worktree prune`, after a stopped `git worktree add`.
    func pruneWorktrees(repoRoot: URL) async throws -> GitResult

    /// Runs `git fetch <remote> refs/heads/<branch>` before a new worktree
    /// starts from the remote's branch. It fetches that one branch of that
    /// one remote, never waiting on a password or a host key no one is
    /// there to answer. Git moves the remote-tracking branch along. A branch the
    /// remote no longer has fails the fetch (`isMissingRemoteBranch`),
    /// where a fetch of the whole remote would leave the tracking branch
    /// as the last fetch saw it.
    func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult

    /// `git fetch <remote> <ref>`: one ref the remote keeps, such as a pull
    /// request's head (`refs/pull/12/head`), and the commit it brought. No
    /// local ref is written: the branch the worktree checks out is made
    /// from the commit, by a rule of ours (`PullRequestBranchChoice`), so a
    /// branch of the person's under the same name never moves.
    func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef

    /// The paths Git ignores in the folder at `repoRoot`, relative to it, a
    /// folder it ignores whole listed once with a trailing `/`.
    func listIgnored(repoRoot: URL) async throws -> [String]

    /// How many commits `upstream` has that `local` lacks; `nil` when
    /// either does not resolve.
    func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int?
}

/// What `GitRunning.fetchRef` brought: git's own result, and the commit
/// when it succeeded.
struct FetchedRef {
    let result: GitResult
    let commit: String?
}

/// Production implementation — thin wrapper that forwards to the
/// existing `GitProcess` static API. Kept as a struct (not `enum`)
/// so it can be stored as `any GitRunning` and value-copied freely.
struct LiveGit: GitRunning {
    func createWorktree(
        repoRoot: URL,
        path: URL,
        baseBranch: String,
        newBranchName: String?
    ) async throws -> GitResult {
        try await GitProcess.createWorktree(
            repoRoot: repoRoot,
            path: path,
            baseBranch: baseBranch,
            newBranchName: newBranchName
        )
    }

    func removeWorktree(
        repoRoot: URL,
        path: URL,
        force: Bool
    ) async throws -> GitResult {
        try await GitProcess.removeWorktree(
            repoRoot: repoRoot,
            path: path,
            force: force
        )
    }

    func createBranch(repoRoot: URL, name: String, startPoint: String) async throws -> GitResult {
        // `--end-of-options`: a name that starts with `-` must not reach
        // `git branch` as an option, where `-D develop` deletes a branch.
        // `--no-track`: a branch started from `origin/main` would take it as
        // its upstream, and status and push would point at the base rather
        // than at the branch's own remote.
        try await GitProcess.run(["branch", "--no-track", "--end-of-options", name, startPoint], cwd: repoRoot)
    }

    func pruneWorktrees(repoRoot: URL) async throws -> GitResult {
        try await GitProcess.pruneWorktrees(repoRoot: repoRoot)
    }

    /// How long a fetch may take before the worktree starts from the local
    /// branch instead: a remote that does not answer must not hold the
    /// sheet for minutes.
    static let fetchTimeout: Duration = .seconds(20)

    func fetch(repoRoot: URL, remote: String, branch: String) async throws -> GitResult {
        // Submodules are not the base's: fetching them would spend the
        // time on what the worktree does not start from. We give no
        // destination: Git writes the branch where the remote's own refspec puts it
        // (`origin/main`), as a fetch of the whole remote would.
        try await GitProcess.run(
            ["fetch", "--quiet", "--no-recurse-submodules", "--end-of-options", remote, "refs/heads/\(branch)"],
            cwd: repoRoot,
            timeout: Self.fetchTimeout,
            environment: Self.fetchEnvironment(repoRoot: repoRoot)
        )
    }

    /// Whether a failed `fetch` failed because the remote has no such
    /// branch, rather than on the way there. We match Git's words under the
    /// C locale `GitProcess` runs it in.
    static func isMissingRemoteBranch(_ result: GitResult) -> Bool {
        !result.succeeded && result.stderr.contains("couldn't find remote ref")
    }

    func fetchRef(repoRoot: URL, remote: String, ref: String) async throws -> FetchedRef {
        // Into a ref of our own rather than FETCH_HEAD, which the base's
        // fetch (the sheet may still be running it) writes to; dropped once
        // read, so nothing of ours stays among the person's refs.
        let landing = "refs/limpid/fetched/\(UUID().uuidString)"
        let result = try await GitProcess.run(
            [
                "fetch",
                "--quiet",
                "--no-tags",
                "--no-write-fetch-head",
                "--no-recurse-submodules",
                "--end-of-options",
                remote,
                "+\(ref):\(landing)"
            ],
            cwd: repoRoot,
            timeout: Self.fetchTimeout,
            environment: Self.fetchEnvironment(repoRoot: repoRoot)
        )
        guard result.succeeded else { return FetchedRef(result: result, commit: nil) }
        let commit = try? await GitProcess.run(["rev-parse", "--verify", "--quiet", "\(landing)^{commit}"], cwd: repoRoot)
        // Best effort: a ref left over names a commit, and costs nothing.
        _ = try? await GitProcess.run(["update-ref", "-d", landing], cwd: repoRoot)
        let sha = commit.flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        return FetchedRef(result: result, commit: sha?.isEmpty == false ? sha : nil)
    }

    /// What a fetch runs with. No prompt can be answered: Git would wait on
    /// the terminal it does not have, and ssh on a passphrase or a new host
    /// key.
    private static func fetchEnvironment(repoRoot: URL) async -> [String: String] {
        var environment = ["GIT_TERMINAL_PROMPT": "0"]
        let inherited = ProcessInfo.processInfo.environment
        let configured = try? await GitProcess.run(["config", "--get", "core.sshCommand"], cwd: repoRoot)
        if let command = batchSSHCommand(
            environment: inherited["GIT_SSH_COMMAND"],
            configured: configured.flatMap { $0.succeeded ? $0.stdout : nil },
            hasSSHProgram: inherited["GIT_SSH"] != nil
        ) {
            environment["GIT_SSH_COMMAND"] = command
        }
        return environment
    }

    /// The ssh command the fetch runs with: the person's own, from the
    /// environment or `core.sshCommand` (a key of their own, a proxy), with
    /// `BatchMode` after it, so it asks nothing; plain `ssh` in batch mode
    /// when they set none. With neither command set, `nil` leaves a program
    /// named by `GIT_SSH` as it is: an option cannot be added to it, and the
    /// variable would replace it.
    ///
    /// Git's own order is kept: `GIT_SSH_COMMAND`, then `core.sshCommand`,
    /// then `GIT_SSH` (git-config(1), `connect.c`). The variable we set
    /// replaces all three, so it carries the one Git would have run. A
    /// command that is a wrapper passing on none of its arguments would not
    /// take the option; that is the person's to say, and rare.
    static func batchSSHCommand(environment: String?, configured: String?, hasSSHProgram: Bool) -> String? {
        let trimmed = { (text: String?) -> String? in
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        if let own = trimmed(environment) ?? trimmed(configured) {
            return own + " -o BatchMode=yes"
        }
        guard !hasSSHProgram else { return nil }
        return "ssh -o BatchMode=yes"
    }

    func listIgnored(repoRoot: URL) async throws -> [String] {
        let result = try await GitProcess.run(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"],
            cwd: repoRoot
        )
        guard result.succeeded else { throw GitProcessError.nonZeroExit(result) }
        return result.stdout.split(separator: "\0").map(String.init)
    }

    func commitsBehind(repoRoot: URL, local: String, upstream: String) async -> Int? {
        let result = try? await GitProcess.run(["rev-list", "--count", "--end-of-options", "\(local)..\(upstream)"], cwd: repoRoot)
        guard let result, result.succeeded else { return nil }
        return Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
