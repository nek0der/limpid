// ReviewRepositoryScenarios.swift
// Limpid — the review scenarios that need a real repository to run against.

// Split from `ReviewValidationScenarios` because these are the ones that spawn
// Git and write to a temporary tree: everything there is a pure function of a
// patch or a row list, and the two kinds of scenario are read and changed for
// different reasons. They stay one type so the `require` helpers and the call
// sites do not move.

import Foundation
@testable import Limpid

extension ReviewValidationScenarios {
    @MainActor
    static func persistence(at directory: URL) async throws {
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await seed(repository)
        let root = try await ReviewGit.root(at: repository)
        let fileURL = root.appendingPathComponent("new.txt")
        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let storage = directory.appendingPathComponent("drafts")
        let store = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await store.refresh()
        guard let file = store.files.first else { throw ReviewValidationFailure(message: "File missing") }
        await store.load(file)
        guard let line = store.diff?.lines.first else { throw ReviewValidationFailure(message: "Line missing") }
        store.add(line: line, body: "Add a test.")
        try require(store.comments.count == 1, "First save failed: \(store.errorMessage ?? "")")
        // A comment over a run keeps both ends through a round-trip.
        let run = store.diff?.lines.filter(\.isCommentable) ?? []
        try require(run.count > 1, "The fixture needs a run of at least two commentable lines")
        store.add(lines: Array(run.prefix(2)), side: nil, body: "Covers a run.")
        guard let ranged = store.comments.last else {
            throw ReviewValidationFailure(message: "Range comment missing")
        }
        try require(ranged.end?.lineID == run[1].id, "Range end not recorded")
        try require(
            ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.last?.end?.lineID == run[1].id,
            "Range did not round-trip"
        )
        store.remove(ranged.id)
        // A run selected in one column of the split layout covers the whole id
        // range, and only the lines that column draws belong to the comment.
        // That needs a replacement to filter: the untracked file above is all
        // additions.
        let tracked = root.appendingPathComponent("tracked.txt")
        try "alpha\nbeta\n".write(to: tracked, atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        _ = try await checkedGit(
            ["-c", "user.email=review@example.com", "-c", "user.name=Review", "commit", "-qm", "seed"],
            cwd: root
        )
        try "gamma\ndelta\n".write(to: tracked, atomically: true, encoding: .utf8)
        await store.refresh()
        guard let replaced = store.files.first(where: { $0.path == "tracked.txt" }) else {
            throw ReviewValidationFailure(message: "The replacement is not in the change list")
        }
        await store.load(replaced)
        let replacement = store.diff?.lines.filter(\.isCommentable) ?? []
        try require(replacement.contains { $0.newLine == nil }, "The replacement has no old-only line")
        try require(replacement.contains { $0.oldLine == nil }, "The replacement has no new-only line")
        store.add(lines: replacement, side: .new, body: "Quote the new side only.")
        guard let sided = store.comments.last, sided.side == .new else {
            throw ReviewValidationFailure(message: "Side comment missing: \(store.errorMessage ?? "")")
        }
        let quoted = Set(sided.code.split(separator: "\n").map(String.init))
        try require(
            replacement.filter { $0.newLine == nil }.allSatisfy { !quoted.contains($0.text) },
            "A new-side comment quoted a line only the old column draws"
        )
        try require(
            sided.anchor.newLine != nil && sided.anchor.oldLine == nil,
            "A new-side comment took an old-side position"
        )
        try require(
            ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.last?.side == .new,
            "The column did not round-trip"
        )
        store.remove(sided.id)
        let restored = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        try require(restored.comments == store.comments, "Draft did not round-trip")
        try await require(
            store.insertable(store.comments).count == store.comments.count,
            "A comment matching the worktree was held back"
        )
        try "modified\n".write(to: fileURL, atomically: true, encoding: .utf8)
        do {
            _ = try await store.insertable(store.comments)
            throw ReviewValidationFailure(message: "Stale comment accepted")
        } catch ReviewError.changed {}
        try require(store.staleCommentIDs.count == 1, "Stale comment not marked")
        store.edit(store.comments[0].id, body: "Edited.")
        try require(store.staleCommentIDs.count == 1, "Editing must not re-anchor a stale comment")
        let id = store.comments[0].id
        store.remove(id)
        try require(ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.isEmpty, "Deletion not persisted")
        let files = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
        guard let saved = files.first else { throw ReviewValidationFailure(message: "Saved file missing") }
        let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Draft permissions")
        try Data("corrupt".utf8).write(to: saved)
        let broken = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await broken.refresh()
        await broken.load(file)
        guard let recovered = broken.diff?.lines.first else {
            throw ReviewValidationFailure(message: "The reopened store has no diff to comment on")
        }
        broken.add(line: recovered, body: "Written after an unreadable draft.")
        // The reader's bytes survive beside a fresh draft, and review keeps
        // working. Refusing to save was meant to protect a draft we could not
        // read, but nothing ever turned saving back on: one unreadable file
        // locked that repository out of review for good, and the only way back
        // was to find the file and delete it.
        let after = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
        guard let quarantined = after.first(where: { $0.lastPathComponent.contains(".bak-decode-failed-") })
        else { throw ReviewValidationFailure(message: "Unreadable draft was not kept") }
        try require(Data(contentsOf: quarantined) == Data("corrupt".utf8), "Unreadable draft was not kept verbatim")
        try require(broken.comments.count == 1, "A comment written after an unreadable draft was refused")
        try require(
            ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.count == 1,
            "The draft written after an unreadable one did not persist"
        )
    }

    /// What a commit does, and does not, do to the fingerprints comments are
    /// written against.
    ///
    /// An unstaged diff is the index against the worktree, so a commit that
    /// leaves both alone must not change it. Folding `HEAD` into the hash
    /// anyway meant every unrelated commit aged out every comment on every
    /// unstaged file — and while an agent is committing in the same worktree,
    /// that is most of them.
    static func fingerprints(at directory: URL) async throws {
        try await seed(directory)
        _ = try await checkedGit(["config", "user.email", "test@limpid.invalid"], cwd: directory)
        _ = try await checkedGit(["config", "user.name", "Limpid Test"], cwd: directory)
        let root = try await ReviewGit.root(at: directory)
        try "one\ntwo\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        let base = try await fixtureGit(["commit", "-m", "base"], cwd: root)
        try require(base.succeeded, "base commit failed: \(base.stderr)")

        try "one\nchanged\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: root.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8)
        let files = try await ReviewGit.files(at: root)
        guard let unstaged = files.first(where: { $0.layer == .unstaged && $0.path == "tracked.txt" }),
              let untracked = files.first(where: { $0.layer == .untracked && $0.path == "untracked.txt" })
        else { throw ReviewValidationFailure(message: "Worktree changes missing") }
        let unstagedBefore = try await ReviewGit.diff(unstaged, root: root).fingerprint
        let untrackedBefore = try await ReviewGit.diff(untracked, root: root).fingerprint
        try await require(ReviewGit.fingerprint(unstaged, root: root) == unstagedBefore, "Unstaged fingerprint agreement")
        try await require(ReviewGit.fingerprint(untracked, root: root) == untrackedBefore, "Untracked fingerprint agreement")

        // The index holds nothing at this point, so this really is an empty
        // commit rather than one that quietly stages the change above.
        let unrelated = try await fixtureGit(["commit", "--allow-empty", "-m", "unrelated"], cwd: root)
        try require(unrelated.succeeded, "unrelated commit failed: \(unrelated.stderr)")
        let unstagedAfter = try await ReviewGit.diff(unstaged, root: root).fingerprint
        try require(unstagedAfter == unstagedBefore, "An unrelated commit aged out an unstaged comment")
        let untrackedAfter = try await ReviewGit.diff(untracked, root: root).fingerprint
        try require(untrackedAfter == untrackedBefore, "An unrelated commit aged out an untracked comment")

        // A staged diff is `HEAD` against the index, but what ages a comment
        // out is the code moving under it, not the ref moving. Written through
        // `commit-tree` because committing would consume the index we are
        // asserting about; the tree is the same one, so nothing the reader is
        // looking at has changed.
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        let staged = try await ReviewGit.files(at: root)
        guard let stagedFile = staged.first(where: { $0.layer == .staged && $0.path == "tracked.txt" }) else {
            throw ReviewValidationFailure(message: "Staged change missing")
        }
        let stagedBefore = try await ReviewGit.diff(stagedFile, root: root).fingerprint
        try await require(ReviewGit.fingerprint(stagedFile, root: root) == stagedBefore, "Staged fingerprint agreement")
        let written = try await fixtureGit(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "moved"], cwd: root)
        try require(written.succeeded, "commit-tree failed: \(written.stderr)")
        let moved = written.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await checkedGit(["update-ref", "HEAD", moved], cwd: root)
        let stagedAfter = try await ReviewGit.diff(stagedFile, root: root).fingerprint
        try require(stagedAfter == stagedBefore, "Moving HEAD over the same tree aged out a staged comment")
        // And the other half: when the staged patch really does change, the
        // fingerprint has to move. Without this the assertion above would pass
        // on a fingerprint that never changes at all.
        try "tracked before\nstaged again\n".write(
            to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8
        )
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        let stagedEdited = try await ReviewGit.diff(stagedFile, root: root).fingerprint
        try require(stagedEdited != stagedBefore, "An edit to the staged content left its fingerprint unchanged")
    }

    /// What the branch view is of, and what a commit does to it.
    ///
    /// Read from the merge base to the worktree rather than `base...HEAD`:
    /// the three-dot form stops at `HEAD`, and an agent that has committed
    /// some of its work and left the rest uncommitted would have the rest
    /// silently missing from the review.
    static func branchScope(at directory: URL) async throws {
        try await seed(directory)
        _ = try await checkedGit(["config", "user.email", "test@limpid.invalid"], cwd: directory)
        _ = try await checkedGit(["config", "user.name", "Limpid Test"], cwd: directory)
        let root = try await ReviewGit.root(at: directory)
        // Ten lines rather than one so the base and the branch can each change
        // a different end of the file. Written on one line apiece, the two
        // edits overlapped and the merge below conflicted — which changed the
        // fingerprint through conflict markers and let the assertion pass
        // without the merge base ever moving.
        let tracked = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        try tracked.write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        _ = try await checkedGit(["commit", "-m", "base"], cwd: root)
        _ = try await checkedGit(["branch", "main-base"], cwd: root)
        _ = try await checkedGit(["checkout", "-q", "-b", "feature"], cwd: root)

        // One committed change and one still in the worktree — the state an
        // agent leaves behind when it says it is done.
        try "committed\n".write(to: root.appendingPathComponent("committed.txt"), atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "committed.txt"], cwd: root)
        _ = try await checkedGit(["commit", "-m", "work"], cwd: root)
        try tracked.replacingOccurrences(of: "line 10", with: "line 10 uncommitted")
            .write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)

        let scope = ReviewScope.branch(base: "main-base")
        let worktreeFiles = try await ReviewGit.files(at: root)
        try require(
            !worktreeFiles.contains { $0.path == "committed.txt" },
            "The worktree view still lists a file that is already committed"
        )
        let branchFiles = try await ReviewGit.files(at: root, scope: scope)
        let branched = branchFiles.filter { $0.layer == .branch }.map(\.path).sorted()
        try require(branched == ["committed.txt", "tracked.txt"], "Branch view carries both the commit and the worktree")

        // A commit of work the branch view already showed moves nothing: it is
        // read against the merge base, and the worktree it ends at is the same.
        guard let file = branchFiles.first(where: { $0.layer == .branch && $0.path == "tracked.txt" }) else {
            throw ReviewValidationFailure(message: "Branch file missing")
        }
        let before = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
        try await require(ReviewGit.fingerprint(file, root: root, base: "main-base") == before, "Branch fingerprint agreement")
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        _ = try await checkedGit(["commit", "-m", "land it"], cwd: root)
        let after = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
        try require(after == before, "Committing work the branch view already showed aged out its comments")

        // The base moving is a different thing, and does change what the
        // branch adds. Committed on the base branch itself, which is what a
        // merge or a rebase of the base looks like from here.
        _ = try await checkedGit(["checkout", "-q", "main-base"], cwd: root)
        // At the other end of the file from the branch's own edit, so the two
        // merge cleanly and what moves is the base rather than the content.
        try ("line 0 from the base\n" + tracked)
            .write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        _ = try await checkedGit(["commit", "-m", "base moves"], cwd: root)
        _ = try await checkedGit(["checkout", "-q", "feature"], cwd: root)
        let merge = try await fixtureGit(["merge", "-q", "--no-edit", "main-base"], cwd: root)
        // Checked, because a conflict leaves markers in the working tree and
        // those move the fingerprint on their own — the assertion below would
        // then pass over a merge base that had not moved at all.
        try require(merge.succeeded, "The fixture's merge conflicted: \(merge.stderr)")
        let base = try await fixtureGit(["merge-base", "feature", "main-base"], cwd: root)
        let tip = try await fixtureGit(["rev-parse", "main-base"], cwd: root)
        try require(
            base.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                == tip.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "The merge base did not move to the base branch's tip"
        )
        let moved = try await ReviewGit.diff(file, root: root, base: "main-base").fingerprint
        try require(moved != before, "A moved merge base left the branch fingerprint unchanged")
    }

    static func conflictAndLimits(at directory: URL) async throws {
        try await seed(directory)
        let path = directory.appendingPathComponent("conflict.txt")
        try "base\n".write(to: path, atomically: true, encoding: .utf8)
        try await checkedGit(["add", "."], cwd: directory)
        try await checkedGit(["commit", "-qm", "base"], cwd: directory)
        try await checkedGit(["checkout", "-qb", "other"], cwd: directory)
        try "other\n".write(to: path, atomically: true, encoding: .utf8)
        try await checkedGit(["commit", "-qam", "other"], cwd: directory)
        try await checkedGit(["checkout", "-q", "main"], cwd: directory)
        try "main\n".write(to: path, atomically: true, encoding: .utf8)
        try await checkedGit(["commit", "-qam", "main"], cwd: directory)
        let merge = try await fixtureGit(["merge", "other"], cwd: directory)
        try require(!merge.succeeded, "The fixture must have a merge conflict")
        let conflicts = try await ReviewGit.files(at: directory).filter { $0.path == "conflict.txt" }
        try require(conflicts.count == 1 && conflicts[0].status == .unmerged, "A conflict must appear exactly once")
        let diff = try await ReviewGit.diff(conflicts[0], root: directory)
        try require(diff.lines.isEmpty && diff.notice != nil, "A conflict must explain why it has no diff")
        try await require(ReviewGit.fingerprint(conflicts[0], root: directory) == diff.fingerprint, "Conflict fingerprint agreement")
        let huge = ReviewFile(path: "huge.txt", layer: .untracked, status: .untracked)
        try String(repeating: "x\n", count: ReviewDiffParser.maxRows + 1)
            .write(to: directory.appendingPathComponent(huge.path), atomically: true, encoding: .utf8)
        try await require(ReviewGit.source(huge, root: directory).isEmpty, "Source rows must respect the parser limit")
        for index in 0..<ReviewGit.maxFiles {
            try Data().write(to: directory.appendingPathComponent("new-\(index).txt"))
        }
        do {
            _ = try await ReviewGit.files(at: directory)
            throw ReviewValidationFailure(message: "The file limit was ignored")
        } catch ReviewError.tooLarge {}
    }

    static func noisyDiagnostics(at directory: URL) async throws {
        try await seed(directory)
        let names = (0..<850).map { String($0) + String(repeating: "a", count: 90) + ".txt" }
        for name in names {
            try "one\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await checkedGit(["add", "."], cwd: directory)
        try await checkedGit(["commit", "-qm", "seed"], cwd: directory)
        for name in names {
            try "two\n".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await checkedGit(["config", "core.autocrlf", "true"], cwd: directory)
        let diagnostics = try await checkedGit(["diff", "--numstat"], cwd: directory)
        try require(diagnostics.stderr.utf8.count > 65536, "The fixture must exceed the former stderr limit")
        let stats = try await ReviewGit.stats(at: directory)
        try require(stats.count == names.count, "Diagnostics must not terminate a successful diff")
    }

    /// We isolate repository identity and configuration without changing the developer's environment.
    static func fixtureGit(_ arguments: [String], cwd: URL) async throws -> GitResult {
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
                    let stdout = Pipe()
                    let stderr = Pipe()
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

    @discardableResult
    static func checkedGit(_ arguments: [String], cwd: URL) async throws -> GitResult {
        let result = try await fixtureGit(arguments, cwd: cwd)
        try require(result.succeeded, "Git fixture command failed: \(arguments.joined(separator: " ")): \(result.stderr)")
        return result
    }

    static func seed(_ directory: URL) async throws {
        let result = try await fixtureGit(["-c", "init.templateDir=", "init", "-q", "-b", "main"], cwd: directory)
        try require(result.succeeded, "git init failed")
        for (key, value) in [
            ("core.autocrlf", "false"), ("commit.gpgsign", "false"),
            ("core.excludesFile", "/dev/null"), ("core.hooksPath", "/dev/null"),
            ("user.email", "review@example.com"), ("user.name", "Review")
        ] {
            let result = try await fixtureGit(["config", key, value], cwd: directory)
            try require(result.succeeded, "Git fixture configuration failed: \(result.stderr)")
        }
    }
}
