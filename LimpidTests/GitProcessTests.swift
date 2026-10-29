// GitProcessTests.swift
// Limpid — running `git`: its deadline, worktree removal, the main checkout, and a detached HEAD.
//
// The two checks against Limpid's own checkout need its `.git` directory
// and skip without it (`RepoFixture.hasLocalRepo`); the rest build their
// repositories with `TempGitRepo`.

import Foundation
import Testing
@testable import Limpid

@Suite("GitProcess smoke", .tags(.smoke))
struct GitProcessSmokeTests {

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func run_gitVersion_reportsGitVersionString() async throws {
        let root = try #require(RepoFixture.limpidRoot)
        let result = try await GitProcess.run(["--version"], cwd: root)
        #expect(result.succeeded, "git --version should succeed: \(result.stderr)")
        #expect(result.stdout.contains("git version"))
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func isGitRepository_returnsTrue_forLimpidRoot() async throws {
        let root = try #require(RepoFixture.limpidRoot)
        let isRepo = await GitProcess.isGitRepository(root)
        #expect(isRepo)
    }

    @Test
    func isGitRepository_returnsFalse_forTmpDirectory() async {
        let isRepo = await GitProcess.isGitRepository(URL(fileURLWithPath: "/tmp"))
        #expect(isRepo == false)
    }

    @Test
    func removeWorktree_withInitializedSubmodule_requiresForce() async throws {
        let repository = try await TempGitRepo.make()
        let submodule = try await TempGitRepo.make()
        defer {
            repository.cleanup()
            submodule.cleanup()
        }

        let addSubmodule = try await GitProcess.run(
            [
                "-c", "protocol.file.allow=always", "submodule", "add", "--",
                submodule.url.path, "deps/submodule"
            ],
            cwd: repository.url
        )
        try #require(addSubmodule.succeeded, "git submodule add failed: \(addSubmodule.stderr)")
        let commit = try await GitProcess.run(
            ["commit", "-m", "Add test submodule"],
            cwd: repository.url
        )
        try #require(commit.succeeded, "git commit failed: \(commit.stderr)")
        let linkedPath = try await repository.addLinkedWorktree(branch: "linked")
        let initialize = try await GitProcess.run(
            ["-c", "protocol.file.allow=always", "submodule", "update", "--init"],
            cwd: linkedPath
        )
        try #require(initialize.succeeded, "git submodule update failed: \(initialize.stderr)")
        let linkedSubmodule = linkedPath.appendingPathComponent("deps/submodule")
        let localCommit = try await GitProcess.run(
            [
                "-c", "user.name=Limpid Tests",
                "-c", "user.email=tests@limpid.invalid",
                "commit", "--allow-empty", "-m", "Local-only submodule commit"
            ],
            cwd: linkedSubmodule
        )
        try #require(localCommit.succeeded, "local submodule commit failed: \(localCommit.stderr)")
        let resolveGitDirectory = try await GitProcess.run(
            ["rev-parse", "--absolute-git-dir"],
            cwd: linkedSubmodule
        )
        try #require(resolveGitDirectory.succeeded, "git-dir lookup failed: \(resolveGitDirectory.stderr)")
        let submoduleGitDirectory = resolveGitDirectory.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(FileManager.default.fileExists(atPath: submoduleGitDirectory))

        let regularRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: false
        )
        #expect(!regularRemoval.succeeded)
        #expect(regularRemoval.stderr.contains("working trees containing submodules"))

        let forcedRemoval = try await GitProcess.removeWorktree(
            repoRoot: repository.url,
            path: linkedPath,
            force: true
        )
        #expect(forcedRemoval.succeeded, "forced removal failed: \(forcedRemoval.stderr)")
        #expect(!FileManager.default.fileExists(atPath: submoduleGitDirectory))
    }

    @Test(.disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
    func gitBranch_takesANameThatLooksLikeAnOption_asAName() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        _ = try await GitProcess.run(["branch", "develop"], cwd: repo.url)
        // Whatever git makes of "-D" as a name, it is not `git branch -D develop`.
        _ = try await LiveGit().createBranch(repoRoot: repo.url, name: "-D", startPoint: "develop")
        #expect(try await LiveGit().createBranch(repoRoot: repo.url, name: "kept", startPoint: "develop").succeeded)
    }
}

/// A git run has a deadline, and the deadline holds whatever git does.
struct GitProcessDeadlineTests {
    /// A `git` that ignores SIGTERM and never finishes, as one waiting in a
    /// hook does.
    private func writeHangingGit(in directory: URL) throws -> GitExecutable {
        let script = directory.appendingPathComponent("git")
        try "#!/bin/sh\ntrap '' TERM\nsleep 30\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return GitExecutable(url: script, leadingArguments: [])
    }

    @Test func aRunPastItsDeadline_isEndedAndThrows() async throws {
        try await withTempDir { directory in
            let git = try writeHangingGit(in: directory)
            let clock = SuspendingClock()
            let started = clock.now
            var thrown: (any Error)?
            do {
                _ = try await GitProcess.run(["status"], cwd: directory, timeout: .seconds(1), executable: git)
            } catch {
                thrown = error
            }
            // The run gives up 1 second for the deadline plus twice the
            // 2-second grace, 5 seconds, when something of the group outlives
            // SIGKILL. The bound is well short of the 30 the script sleeps
            // and leaves room for a busy CI runner.
            #expect(clock.now - started < .seconds(15), "the deadline and the grace, not the script's own end")
            guard case let .timedOut(seconds, _)? = thrown as? GitProcessError else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(seconds == 1)
        }
    }

    /// Git starts a hook that ignores SIGTERM, while git itself ends on
    /// it: the hook is ended too, before the run returns, so nothing of it
    /// writes in a folder the caller clears and makes again.
    @Test func aRunPastItsDeadline_endsWhatItStarted_evenWhenThatIgnoresSIGTERM() async throws {
        try await withTempDir { directory in
            let pidFile = directory.appendingPathComponent("hook.pid")
            let script = directory.appendingPathComponent("git")
            try """
            #!/bin/sh
            sh -c 'trap "" TERM; echo $$ > "$1.tmp"; mv "$1.tmp" "$1"; while :; do sleep 1; done' hook '\(pidFile.path)' &
            sleep 30
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let git = GitExecutable(url: script, leadingArguments: [])

            var thrown: (any Error)?
            do {
                _ = try await GitProcess.run(["worktree", "add"], cwd: directory, timeout: .seconds(1), executable: git)
            } catch {
                thrown = error
            }

            guard case let .timedOut(_, hasProcessesLeft)? = thrown as? GitProcessError else {
                Issue.record("expected a timeout, got \(String(describing: thrown))")
                return
            }
            #expect(!hasProcessesLeft)
            let pid = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(!ProcessLiveness.isLive(pid), "the hook is gone once the run returns")
        }
    }

    @Test func aTimeout_saysHowLongGitHad() {
        let message = GitProcessError.timedOut(seconds: 60).message
        #expect(message.resolved(in: Locale(identifier: "en")) == "git didn’t finish within 60 seconds.")
        #expect(message.resolved(in: Locale(identifier: "ja")) == "git が 60 秒以内に完了しませんでした。")
    }
}

@Suite("GitProcess resolveMainCheckout", .tags(.smoke))
struct GitProcessResolveMainCheckoutTests {

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forNonGitDirectory() async throws {
        try await withTempDir { tmp in
            let resolved = await GitProcess.resolveMainCheckout(of: tmp)

            #expect(resolved.standardizedFileURL == tmp.standardizedFileURL)
        }
    }

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forMainCheckoutRoot() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }

        let resolved = await GitProcess.resolveMainCheckout(of: repo.url)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }

    @Test
    func resolveMainCheckout_returnsURLUnchanged_forSubdirectoryOfMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let subdir = repo.url.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)

        let resolved = await GitProcess.resolveMainCheckout(of: subdir)

        // Subdirectories under a working tree are an intentional
        // anchor — the resolver must not promote them.
        #expect(resolved.standardizedFileURL == subdir.standardizedFileURL)
    }

    @Test
    func resolveMainCheckout_promotesLinkedWorktreeRoot_toMainCheckout() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let linkedPath = try await repo.addLinkedWorktree(branch: "feature")

        let resolved = await GitProcess.resolveMainCheckout(of: linkedPath)

        #expect(resolved.standardizedFileURL == repo.url.standardizedFileURL)
    }
}

struct GitProcessShortHeadTests {
    @Test func aDetachedHead_isNamedByItsShortCommit() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let full = try await GitProcess.run(["rev-parse", "HEAD"], cwd: repo.url).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await GitProcess.run(["checkout", "-q", "--detach"], cwd: repo.url)
        let branch = try await GitProcess.currentBranch(repoRoot: repo.url)
        #expect(branch == nil)
        let head = try await GitProcess.shortHead(repoRoot: repo.url)
        let short = try #require(head)
        #expect(short.count >= 7)
        #expect(full.hasPrefix(short))
    }

    @Test func aFolderOutsideARepository_hasNoCommit() async throws {
        let commit: String? = try await withTempDir { folder in
            try await GitProcess.shortHead(repoRoot: folder)
        }
        #expect(commit == nil)
    }
}
