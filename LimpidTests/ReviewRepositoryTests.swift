// ReviewRepositoryTests.swift
// Limpid — what review reads from a real repository: layers, fingerprints, the branch view, and limits.

import Foundation
import Testing
@testable import Limpid

struct ReviewRepositoryTests {
    @Test func gitSeparatesStagedUnstagedAndUntrackedChanges() async throws {
        try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
            let root = try await ReviewGit.root(at: directory)
            let names = ["日本語 space.txt", "tab\tname.txt", "line\nname.txt", "quote\"name.txt", "back\\slash.txt", "bell\u{7}.txt"]
            for name in names {
                try "before\r\n".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            _ = try await ReviewGitFixture.checked(["add", "--"] + names, cwd: root)
            for name in names {
                try "after\r\nextra".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            _ = try await ReviewGitFixture.checked(["config", "diff.outputIndicatorNew", ">"], cwd: root)
            _ = try await ReviewGitFixture.checked(["config", "diff.suppressBlankEmpty", "true"], cwd: root)
            let files = try await ReviewGit.files(at: root)
            #expect(files.count == names.count * 2, "Staged and unstaged files stay separate")
            for file in files.filter({ $0.layer == .unstaged }) {
                let diff = try await ReviewGit.diff(file, root: root)
                #expect(try await ReviewGit.fingerprint(file, root: root) == diff.fingerprint, "Polling and display fingerprints agree")
                #expect(diff.lines.filter { $0.kind == .added }.map(\.newLine) == [1, 2], "Actual Git line numbers")
                // The fixture above is CRLF. A carriage return belongs to the
                // file's encoding rather than to the line being reviewed, and one
                // left on the end is refused on the way to a terminal — a comment
                // on a Windows-authored file could be written and never sent.
                #expect(diff.lines.allSatisfy { !$0.text.hasSuffix("\r") }, "A carriage return survived the diff")
            }
            let tracked = try #require(files.first(where: { $0.layer == .unstaged }), "No unstaged file to grow past the limit")
            try Data(repeating: 120, count: ReviewGit.maxDiffBytes + 1).write(to: root.appendingPathComponent(tracked.path))
            await #expect(throws: ReviewError.tooLarge, "Oversized Git output accepted") {
                try await ReviewGit.diff(tracked, root: root)
            }
            let newFile = root.appendingPathComponent("new.txt")
            try "new\r\n".write(to: newFile, atomically: true, encoding: .utf8)
            let updated = try await ReviewGit.files(at: root)
            let untracked = try #require(updated.first(where: { $0.path == "new.txt" }), "Untracked file missing")
            let diff = try await ReviewGit.diff(untracked, root: root)
            try #require(diff.lines.count == 1, "Untracked additions")
            #expect(diff.lines[0].newLine == 1, "Untracked additions")
            // The untracked route builds its rows without going through `parse`,
            // and used to keep the carriage return the tracked one drops.
            #expect(diff.lines[0].text == "new", "Untracked lines read like tracked ones")
            // Direct symlinks are refused even when both targets are inside the worktree.
            let outside = directory.appendingPathComponent("outside.txt")
            try "secret\n".write(to: outside, atomically: true, encoding: .utf8)
            let escaping = root.appendingPathComponent("escaping.txt")
            let inside = root.appendingPathComponent("inside.txt")
            try FileManager.default.createSymbolicLink(at: escaping, withDestinationURL: outside)
            try FileManager.default.createSymbolicLink(at: inside, withDestinationURL: newFile)
            defer {
                try? FileManager.default.removeItem(at: escaping)
                try? FileManager.default.removeItem(at: inside)
                try? FileManager.default.removeItem(at: outside)
            }
            let withLinks = try await ReviewGit.files(at: root)
            for name in ["escaping.txt", "inside.txt"] {
                let link = try #require(withLinks.first(where: { $0.path == name }), "Symlink not listed: \(name)")
                await #expect(throws: ReviewError.unsupported, "A symlink was read as a file: \(name)") {
                    try await ReviewGit.diff(link, root: root)
                }
            }
            let nested = root.appendingPathComponent("nested-repo")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try await TempGitRepo.initialize(nested)
            let nestedRoot = try await ReviewGit.root(at: nested)
            try FileManager.default.createSymbolicLink(at: nestedRoot.appendingPathComponent("link"), withDestinationURL: root)
            let escaped = ReviewFile(path: "link/outside.txt", layer: .untracked, status: .untracked)
            #expect(await ReviewGit.source(escaped, root: nestedRoot).isEmpty, "A parent symlink escaped the repository")
            await #expect(throws: ReviewError.unsupported, "A parent symlink exposed external file content") {
                try await ReviewGit.diff(escaped, root: nestedRoot)
            }
            try Data([0, 1]).write(to: newFile)
            await #expect(throws: ReviewError.self, "Binary accepted") { try await ReviewGit.diff(untracked, root: root) }
            try Data(repeating: 97, count: ReviewGit.maxDiffBytes + 1).write(to: newFile)
            await #expect(throws: ReviewError.self, "Oversized file accepted") { try await ReviewGit.diff(untracked, root: root) }
        }
    }

    /// What a commit does, and does not, do to the fingerprints comments are
    /// written against.
    ///
    /// An unstaged diff is the index against the worktree, so a commit that
    /// leaves both alone must not change it. Folding `HEAD` into the hash
    /// anyway meant every unrelated commit aged out every comment on every
    /// unstaged file — and while an agent is committing in the same worktree,
    /// that is most of them.
    @Test func aCommitAgesOutStagedFingerprintsOnly() async throws {
        try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
            let root = try await ReviewGit.root(at: directory)
            try "one\ntwo\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            let base = try await ReviewGitFixture.run(["commit", "-m", "base"], cwd: root)
            try #require(base.succeeded, "base commit failed: \(base.stderr)")

            try "one\nchanged\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            try "new\n".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
            let files = try await ReviewGit.files(at: root)
            let unstaged = try #require(
                files.first { $0.layer == .unstaged && $0.path == "tracked.txt" },
                "Worktree changes missing"
            )
            let untracked = try #require(
                files.first { $0.layer == .untracked && $0.path == "untracked.txt" },
                "Worktree changes missing"
            )
            let unstagedBefore = try await ReviewGit.diff(unstaged, root: root).fingerprint
            let untrackedBefore = try await ReviewGit.diff(untracked, root: root).fingerprint
            #expect(try await ReviewGit.fingerprint(unstaged, root: root) == unstagedBefore, "Unstaged fingerprint agreement")
            #expect(try await ReviewGit.fingerprint(untracked, root: root) == untrackedBefore, "Untracked fingerprint agreement")

            // The index holds nothing at this point, so this really is an empty
            // commit rather than one that quietly stages the change above.
            let unrelated = try await ReviewGitFixture.run(["commit", "--allow-empty", "-m", "unrelated"], cwd: root)
            try #require(unrelated.succeeded, "unrelated commit failed: \(unrelated.stderr)")
            let unstagedAfter = try await ReviewGit.diff(unstaged, root: root).fingerprint
            #expect(unstagedAfter == unstagedBefore, "An unrelated commit aged out an unstaged comment")
            let untrackedAfter = try await ReviewGit.diff(untracked, root: root).fingerprint
            #expect(untrackedAfter == untrackedBefore, "An unrelated commit aged out an untracked comment")

            // A staged diff is `HEAD` against the index, but what ages a comment
            // out is the code moving under it, not the ref moving. Written through
            // `commit-tree` because committing would consume the index we are
            // asserting about; the tree is the same one, so nothing the reader is
            // looking at has changed.
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            let staged = try await ReviewGit.files(at: root)
            let stagedFile = try #require(staged.first(where: { $0.layer == .staged && $0.path == "tracked.txt" }), "Staged change missing")
            let stagedBefore = try await ReviewGit.diff(stagedFile, root: root).fingerprint
            #expect(try await ReviewGit.fingerprint(stagedFile, root: root) == stagedBefore, "Staged fingerprint agreement")
            let written = try await ReviewGitFixture.run(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "moved"], cwd: root)
            try #require(written.succeeded, "commit-tree failed: \(written.stderr)")
            let moved = written.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await ReviewGitFixture.checked(["update-ref", "HEAD", moved], cwd: root)
            let stagedAfter = try await ReviewGit.diff(stagedFile, root: root).fingerprint
            #expect(stagedAfter == stagedBefore, "Moving HEAD over the same tree aged out a staged comment")
            // And the other half: when the staged patch really does change, the
            // fingerprint has to move. Without this the assertion above would pass
            // on a fingerprint that never changes at all.
            try "tracked before\nstaged again\n".write(
                to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
            )
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            let stagedEdited = try await ReviewGit.diff(stagedFile, root: root).fingerprint
            #expect(stagedEdited != stagedBefore, "An edit to the staged content left its fingerprint unchanged")
        }
    }

    /// What the branch view is of, and what a commit does to it.
    ///
    /// Read from the merge base to the worktree rather than `base...HEAD`:
    /// the three-dot form stops at `HEAD`, and an agent that has committed
    /// some of its work and left the rest uncommitted would have the rest
    /// silently missing from the review.
    @Test func branchViewCarriesCommittedAndUncommittedWorkTogether() async throws {
        try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
            let root = try await ReviewGit.root(at: directory)
            // Ten lines rather than one so the base and the branch can each change
            // a different end of the file. Written on one line apiece, the two
            // edits overlapped and the merge below conflicted — which changed the
            // fingerprint through conflict markers and let the assertion pass
            // without the merge base ever moving.
            let tracked = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
            try tracked.write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(["commit", "-m", "base"], cwd: root)
            _ = try await ReviewGitFixture.checked(["branch", "main-base"], cwd: root)
            _ = try await ReviewGitFixture.checked(["checkout", "-q", "-b", "feature"], cwd: root)

            // One committed change and one still in the worktree — the state an
            // agent leaves behind when it says it is done.
            try "committed\n".write(to: root.appendingPathComponent("committed.txt"), atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "committed.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(["commit", "-m", "work"], cwd: root)
            try tracked.replacingOccurrences(of: "line 10", with: "line 10 uncommitted")
                .write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

            let scope = ReviewScope.branch(base: "main-base")
            let worktreeFiles = try await ReviewGit.files(at: root)
            #expect(
                !worktreeFiles.contains { $0.path == "committed.txt" },
                "The worktree view still lists a file that is already committed"
            )
            let branchFiles = try await ReviewGit.files(at: root, scope: scope)
            let branched = branchFiles.filter { $0.layer == .branch }.map(\.path).sorted()
            #expect(branched == ["committed.txt", "tracked.txt"], "Branch view carries both the commit and the worktree")

            // A commit of work the branch view already showed moves nothing: it is
            // read against the merge base, and the worktree it ends at is the same.
            let file = try #require(branchFiles.first(where: { $0.layer == .branch && $0.path == "tracked.txt" }), "Branch file missing")
            let before = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
            #expect(try await ReviewGit.fingerprint(file, root: root, base: "main-base") == before, "Branch fingerprint agreement")
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(["commit", "-m", "land it"], cwd: root)
            let after = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
            #expect(after == before, "Committing work the branch view already showed aged out its comments")

            // The base moving is a different thing, and does change what the
            // branch adds. Committed on the base branch itself, which is what a
            // merge or a rebase of the base looks like from here.
            _ = try await ReviewGitFixture.checked(["checkout", "-q", "main-base"], cwd: root)
            // At the other end of the file from the branch's own edit, so the two
            // merge cleanly and what moves is the base rather than the content.
            try ("line 0 from the base\n" + tracked)
                .write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(["commit", "-m", "base moves"], cwd: root)
            _ = try await ReviewGitFixture.checked(["checkout", "-q", "feature"], cwd: root)
            let merge = try await ReviewGitFixture.run(["merge", "-q", "--no-edit", "main-base"], cwd: root)
            // Checked, because a conflict leaves markers in the working tree and
            // those move the fingerprint on their own — the assertion below would
            // then pass over a merge base that had not moved at all.
            try #require(merge.succeeded, "The fixture's merge conflicted: \(merge.stderr)")
            let base = try await ReviewGitFixture.run(["merge-base", "feature", "main-base"], cwd: root)
            let tip = try await ReviewGitFixture.run(["rev-parse", "main-base"], cwd: root)
            #expect(
                base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                    == tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                "The merge base did not move to the base branch's tip"
            )
            let moved = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
            #expect(moved != before, "A moved merge base left the branch fingerprint unchanged")
        }
    }

    @Test func conflictsAndSizeLimitsAreSaidOutright() async throws {
        try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
            let path = directory.appendingPathComponent("conflict.txt")
            try "base\n".write(to: path, atomically: true, encoding: .utf8)
            try await ReviewGitFixture.checked(["add", "."], cwd: directory)
            try await ReviewGitFixture.checked(["commit", "-qm", "base"], cwd: directory)
            try await ReviewGitFixture.checked(["checkout", "-qb", "other"], cwd: directory)
            try "other\n".write(to: path, atomically: true, encoding: .utf8)
            try await ReviewGitFixture.checked(["commit", "-qam", "other"], cwd: directory)
            try await ReviewGitFixture.checked(["checkout", "-q", "main"], cwd: directory)
            try "main\n".write(to: path, atomically: true, encoding: .utf8)
            try await ReviewGitFixture.checked(["commit", "-qam", "main"], cwd: directory)
            let merge = try await ReviewGitFixture.run(["merge", "other"], cwd: directory)
            try #require(!merge.succeeded, "The fixture must have a merge conflict")
            let conflicts = try await ReviewGit.files(at: directory).filter { $0.path == "conflict.txt" }
            try #require(conflicts.count == 1, "A conflict must appear exactly once")
            #expect(conflicts[0].status == .unmerged, "A conflict must appear exactly once")
            let diff = try await ReviewGit.diff(conflicts[0], root: directory)
            #expect(diff.lines.isEmpty && diff.notice != nil, "A conflict must explain why it has no diff")
            #expect(try await ReviewGit.fingerprint(conflicts[0], root: directory) == diff.fingerprint, "Conflict fingerprint agreement")
            let huge = ReviewFile(path: "huge.txt", layer: .untracked, status: .untracked)
            try String(repeating: "x\n", count: ReviewDiffParser.maxRows + 1)
                .write(to: directory.appendingPathComponent(huge.path), atomically: true, encoding: .utf8)
            #expect(await ReviewGit.source(huge, root: directory).isEmpty, "Source rows must respect the parser limit")
            for index in 0..<ReviewGit.maxFiles {
                try Data().write(to: directory.appendingPathComponent("new-\(index).txt"))
            }
            await #expect(throws: ReviewError.tooLarge, "The file limit was ignored") { try await ReviewGit.files(at: directory) }
        }
    }

    @Test func diagnosticsDoNotConsumeThePayloadBudget() async throws {
        try await withTempDir { directory in
            try await TempGitRepo.initialize(directory)
            let names = (0..<850).map { String($0) + String(repeating: "a", count: 90) + ".txt" }
            for name in names {
                try "one\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try await ReviewGitFixture.checked(["add", "."], cwd: directory)
            try await ReviewGitFixture.checked(["commit", "-qm", "seed"], cwd: directory)
            for name in names {
                try "two\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
            try await ReviewGitFixture.checked(["config", "core.autocrlf", "true"], cwd: directory)
            let diagnostics = try await ReviewGitFixture.checked(["diff", "--numstat"], cwd: directory)
            try #require(diagnostics.stderr.utf8.count > 65536, "The fixture must exceed the former stderr limit")
            let stats = try await ReviewGit.stats(at: directory)
            #expect(stats.count == names.count, "Diagnostics must not terminate a successful diff")
        }
    }
}
