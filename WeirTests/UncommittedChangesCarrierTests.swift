// UncommittedChangesCarrierTests.swift
// Weir — moving a worktree's uncommitted changes into a new one with real git, and that no failure loses or alters them.

import Foundation
import Testing
@testable import Weir

@Suite(.timeLimit(.minutes(1)))
struct UncommittedChangesCarrierTests {

    // MARK: - Fixture

    /// A repository with a few committed files of each kind (text, binary,
    /// script, symlink) and nothing uncommitted.
    private static func makeRepository() async throws -> TempGitRepo {
        let repo = try await TempGitRepo.make()
        try write("a\nb\nc\n", to: "a.txt", in: repo.url)
        try write("keep\n", to: "x.txt", in: repo.url)
        try write("gone\n", to: "deleted.txt", in: repo.url)
        try Data([0, 1, 2, 255]).write(to: repo.url.appendingPathComponent("image.bin"))
        try write("#!/bin/sh\n", to: "run.sh", in: repo.url)
        try FileManager.default.createSymbolicLink(atPath: repo.url.appendingPathComponent("link").path, withDestinationPath: "a.txt")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", "files"])
        return repo
    }

    /// Every kind of change: staged, then changed again unstaged; a staged
    /// rename; a binary change; a deletion; a mode change; a symlink
    /// removed; untracked files, one in a new folder.
    private static func makeChanges(in root: URL) async throws {
        try write("a\nB\nc\n", to: "a.txt", in: root)
        try await TempGitRepo.git(["add", "a.txt"], in: root)
        try write("a\nB\nc\nd\n", to: "a.txt", in: root)
        try await TempGitRepo.git(["mv", "x.txt", "y.txt"], in: root)
        try Data([0, 9, 9, 255]).write(to: root.appendingPathComponent("image.bin"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted.txt"))
        try await TempGitRepo.git(["update-index", "--chmod=+x", "run.sh"], in: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("link"))
        try write("new\n", to: "notes.txt", in: root)
        try write("deep\n", to: "dir/inner.txt", in: root)
    }

    private static func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private static func read(_ path: String, in root: URL) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private static func status(_ root: URL) async throws -> String {
        try await TempGitRepo.git(["status", "--porcelain=v1", "--untracked-files=all"], in: root)
    }

    /// What a worktree holds, beyond `status`: the index as a tree, and the
    /// bytes of every file `status` lists.
    private static func state(_ root: URL) async throws -> [String] {
        let tree = try await TempGitRepo.git(["write-tree"], in: root)
        var state = try await [tree, status(root)]
        for path in ["a.txt", "y.txt", "image.bin", "notes.txt", "dir/inner.txt", "later.txt"] {
            let data = FileManager.default.contents(atPath: root.appendingPathComponent(path).path)
            state.append("\(path): \(data.map { Array($0).description } ?? "none")")
        }
        return state
    }

    /// A worktree beside the repository on a new branch from `start`, as
    /// the sheet makes one.
    private static func addTarget(_ repo: TempGitRepo, branch: String, start: String = "HEAD") async throws -> URL {
        let target = repo.url.deletingLastPathComponent().appendingPathComponent("\(repo.url.lastPathComponent)-\(branch)")
        try await repo.git(["worktree", "add", "-q", "-b", branch, target.path, start])
        return target
    }

    private static func carry(_ repo: TempGitRepo, onto start: String = "HEAD", target: URL) async throws
        -> (UncommittedChangesCarrier.Snapshot, UncommittedChangesCarrier.Outcome)
    {
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: start, repoRoot: repo.url)
        return await (snapshot, UncommittedChangesCarrier.move(snapshot, placement: placement, into: target))
    }

    // MARK: - Moving

    /// Onto the same commit, the new worktree ends up exactly as the source
    /// was, the staged and the unstaged kept apart, and the source is clean.
    @Test func everyKindOfChange_moves_stagedAndUnstagedApart_andTheSourceIsClean() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (snapshot, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .moved(files: snapshot.fileCount))
        #expect(snapshot.fileCount == 8)
        #expect(try await Self.state(target) == before)
        #expect(try await TempGitRepo.git(["ls-files", "-s", "run.sh"], in: target).hasPrefix("100755"))
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("link").path))
        // The source is back at its commit: the symlink and the deleted file
        // are there again, the new folder is gone.
        #expect(try await Self.status(repo.url).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.url.appendingPathComponent("dir").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: repo.url.appendingPathComponent("link").path)) == "a.txt")
        #expect(try Self.read("deleted.txt", in: repo.url) == "gone\n")
    }

    /// Onto a start a commit ahead that touches other files, the changes
    /// are merged onto it.
    @Test func ontoAnotherStart_theChangesAreMergedOntoIt() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let ahead = try await Self.addTarget(repo, branch: "ahead")
        try Self.write("theirs\n", to: "other.txt", in: ahead)
        try await TempGitRepo.git(["add", "other.txt"], in: ahead)
        try await TempGitRepo.git(["commit", "-q", "-m", "ahead"], in: ahead)
        let start = try await TempGitRepo.git(["rev-parse", "HEAD"], in: ahead)
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried", start: start)

        let (_, outcome) = try await Self.carry(repo, onto: start, target: target)

        guard case .moved = outcome else {
            Issue.record("not moved: \(outcome)")
            return
        }
        #expect(try Self.read("other.txt", in: target) == "theirs\n")
        #expect(try Self.read("a.txt", in: target) == "a\nB\nc\nd\n")
        #expect(try await TempGitRepo.git(["diff", "--cached", "--name-status", "--no-renames", "--", "a.txt"], in: target) == "M\ta.txt")
        #expect(try await Self.status(repo.url).isEmpty)
    }

    /// A start that changed the same lines stops the carry before anything
    /// is made, naming the file; the source is as it was.
    @Test func aConflictWithTheStart_stopsBeforeAnything_andTheSourceIsAsItWas() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let ahead = try await Self.addTarget(repo, branch: "ahead")
        try Self.write("a\nTHEIRS\nc\n", to: "a.txt", in: ahead)
        try await TempGitRepo.git(["commit", "-q", "-am", "theirs"], in: ahead)
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))

        await #expect(throws: UncommittedCarryRefusal.conflicts(["a.txt"])) {
            try await UncommittedChangesCarrier.place(snapshot, onto: "ahead", repoRoot: repo.url)
        }
        #expect(try await Self.state(repo.url) == before)
    }

    // MARK: - The source changing meanwhile

    /// A file changed after the changes were read: the new worktree's copy
    /// is not the source's any more, and the source keeps
    /// everything, the late edit included.
    @Test func aFileChangedMeanwhile_leavesTheSourceAsItIsNow() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try Self.write("a\nB\nc\nd\nlater\n", to: "a.txt", in: repo.url)
        let now = try await Self.state(repo.url)

        let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target)

        // The new worktree no longer has the source's bytes, so it is put
        // back; an edit in the moment after that check stops the clearing
        // instead (`aCommitMadeWhileTheIndexIsHeld_isKept` goes that far).
        #expect(outcome == .notApplied)
        #expect(try await Self.state(repo.url) == now)
        #expect(try Self.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await TempGitRepo.git(["status", "--porcelain"], in: target).isEmpty)
    }

    /// A file deleted in the changes comes back as an untracked one (an
    /// agent wrote it): taking the deletion away would overwrite it.
    @Test func anUntrackedFileWhereADeletionWas_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try Self.write("agent wrote this\n", to: "deleted.txt", in: repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .notApplied)
        #expect(try Self.read("deleted.txt", in: repo.url) == "agent wrote this\n")
        #expect(try Self.read("notes.txt", in: repo.url) == "new\n")
    }

    /// A commit made meanwhile: going back to the old HEAD would undo it.
    @Test func aCommitMadeMeanwhile_leavesTheSourceAlone() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        try await repo.git(["commit", "-q", "-m", "meanwhile"])
        let now = try await Self.state(repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .leftInSource)
        #expect(try await Self.state(repo.url) == now)
    }

    /// Another Git holds the source's index: the source is left as it is,
    /// and the other's lock is not ours to remove.
    @Test func anIndexAnotherGitHolds_isLeftAlone_withItsLock() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let now = try Self.read("a.txt", in: repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .leftInSource)
        #expect(FileManager.default.fileExists(atPath: lock.path))
        #expect(try Self.read("a.txt", in: repo.url) == now)
        #expect(try Self.read("notes.txt", in: repo.url) == "new\n")
    }

    /// The new worktree cannot take the changes (its checkout made a file
    /// where one goes): it is left with what it had, and the source is not
    /// touched.
    @Test func aTargetThatRefuses_isNotApplied_andTheSourceIsUntouched() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        try Self.write("made by a hook\n", to: "notes.txt", in: target)

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try await Self.state(repo.url) == before)
        #expect(try Self.read("notes.txt", in: target) == "made by a hook\n")
    }

    /// The new worktree's checkout hook changed a tracked file the changes
    /// do not touch: the carry writes nothing there, so the hook's change
    /// is kept rather than taken back with a failed check.
    @Test func aTrackedFileTheHookChanged_isKept_andNothingIsWritten() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("a\nB\nc\n", to: "a.txt", in: repo.url)
        let before = try await Self.state(repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")
        try Self.write("made by a hook\n", to: "x.txt", in: target)

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try Self.read("x.txt", in: target) == "made by a hook\n")
        #expect(try Self.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(target) == "M x.txt")
        #expect(try await Self.state(repo.url) == before)
    }

    /// A check that fails after the changes were written puts back only
    /// the paths they wrote: the files they added go, and an untracked
    /// file of the new worktree's own stays.
    @Test func aFailedCheck_putsBackOnlyWhatTheChangesWrote() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("* text=auto\n", to: ".gitattributes", in: repo.url)
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try Data("a\r\nCRLF\r\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        try Self.write("new\n", to: "notes.txt", in: repo.url)
        try await repo.git(["add", "notes.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")
        try Self.write("installed by a hook\n", to: "vendor/lib.txt", in: target)

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try Self.read("vendor/lib.txt", in: target) == "installed by a hook\n")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt").path))
        #expect(try Self.read("a.txt", in: target) == "a\nb\nc\n")
        #expect(try await Self.status(target) == "?? vendor/lib.txt")
    }

    // MARK: - What stops it first

    @Test func nothingToCarry_isNone() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        #expect(try await UncommittedChangesCarrier.snapshot(of: repo.url) == nil)
    }

    @Test func aBranchWithNoCommit_isRefused() async throws {
        try await withTempDir { dir in
            try await TempGitRepo.initialize(dir)
            try Self.write("x\n", to: "x.txt", in: dir)
            await #expect(throws: UncommittedCarryRefusal.noCommit) {
                try await UncommittedChangesCarrier.snapshot(of: dir)
            }
        }
    }

    @Test func aMergeUnderWay_isRefused_andItsStateIsLeft() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let other = try await Self.addTarget(repo, branch: "other")
        try Self.write("a\nOTHER\nc\n", to: "a.txt", in: other)
        try await TempGitRepo.git(["commit", "-q", "-am", "other"], in: other)
        try Self.write("a\nMINE\nc\n", to: "a.txt", in: repo.url)
        try await repo.git(["commit", "-q", "-am", "mine"])
        _ = try? await repo.git(["merge", "-q", "other"])
        let before = try await Self.status(repo.url)

        await #expect(throws: UncommittedCarryRefusal.operationInProgress) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try await Self.status(repo.url) == before)
        #expect(FileManager.default.fileExists(atPath: repo.url.appendingPathComponent(".git/MERGE_HEAD").path))
    }

    @Test func aRepositoryInsideTheWorktree_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let inner = repo.url.appendingPathComponent("vendor/inner")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try await TempGitRepo.initialize(inner)
        try await TempGitRepo.git(["commit", "-q", "--allow-empty", "-m", "inner"], in: inner)

        await #expect(throws: UncommittedCarryRefusal.submodules) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    @Test func aSparseCheckout_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["config", "core.sparseCheckout", "true"])
        try Self.write("x\n", to: "a.txt", in: repo.url)
        await #expect(throws: UncommittedCarryRefusal.unsupportedCheckout) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    /// Reading the changes writes nothing in the source, its index included.
    @Test func readingTheChanges_writesNothingInTheSource() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        // The state first: its own `git status` may refresh the index.
        let before = try await Self.state(repo.url)
        let index = repo.url.appendingPathComponent(".git/index")
        let indexBefore = try Data(contentsOf: index)

        _ = try await UncommittedChangesCarrier.snapshot(of: repo.url)

        #expect(try Data(contentsOf: index) == indexBefore)
        #expect(try await Self.state(repo.url) == before)
    }

    /// A file marked skip-worktree: only the index holds the mark, and
    /// taking the changes away replaces the index.
    @Test func aFileMarkedSkipWorktree_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await repo.git(["update-index", "--skip-worktree", "x.txt"])
        try Self.write("x\n", to: "a.txt", in: repo.url)
        await #expect(throws: UncommittedCarryRefusal.indexOnlyState) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    @Test func aFileAddedWithIntentToAdd_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("later\n", to: "later.txt", in: repo.url)
        try await repo.git(["add", "-N", "later.txt"])
        await #expect(throws: UncommittedCarryRefusal.indexOnlyState) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
    }

    /// A tracked file turned into a folder that holds a file Git ignores:
    /// going back to the file would remove the ignored one, which nothing
    /// carries.
    @Test func aFileTurnedFolder_withAnIgnoredFileInIt_isRefused() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("*.log\n", to: ".gitignore", in: repo.url)
        try await repo.git(["add", ".gitignore"])
        try await repo.git(["commit", "-q", "-m", "ignore"])
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("x.txt"))
        try Self.write("tracked later\n", to: "x.txt/y.txt", in: repo.url)
        try Self.write("keep me\n", to: "x.txt/keep.log", in: repo.url)

        await #expect(throws: UncommittedCarryRefusal.ignoredFilesInTheWay("x.txt")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try Self.read("x.txt/keep.log", in: repo.url) == "keep me\n")
    }

    /// A file taken out of Git and ignored since (`.env` with real values),
    /// where HEAD still has it: going back to HEAD would write the
    /// committed one over it.
    @Test func anIgnoredFileWhereADeletionIs_isRefused_andKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("SECRET=template\n", to: ".env", in: repo.url)
        try await repo.git(["add", ".env"])
        try await repo.git(["commit", "-q", "-m", "env"])
        try await repo.git(["rm", "-q", "--cached", ".env"])
        try Self.write(".env\n", to: ".gitignore", in: repo.url)
        try Self.write("SECRET=real\n", to: ".env", in: repo.url)

        await #expect(throws: UncommittedCarryRefusal.ignoredFilesInTheWay(".env")) {
            try await UncommittedChangesCarrier.snapshot(of: repo.url)
        }
        #expect(try Self.read(".env", in: repo.url) == "SECRET=real\n")
    }

    /// Git stores a file as its line-ending setting says, so a file with
    /// CRLF line ends could come out with LF ones and still match: the new
    /// worktree is compared byte for byte, and the source keeps its file.
    @Test func aFileGitWouldStoreOtherwise_isNotApplied_andTheSourceKeepsItsBytes() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("* text=auto\n", to: ".gitattributes", in: repo.url)
        try await repo.git(["add", ".gitattributes"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try Data("a\r\nCRLF\r\n".utf8).write(to: repo.url.appendingPathComponent("a.txt"))
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        #expect(outcome == .notApplied)
        #expect(try Data(contentsOf: repo.url.appendingPathComponent("a.txt")) == Data("a\r\nCRLF\r\n".utf8))
        #expect(try await TempGitRepo.git(["status", "--porcelain"], in: target).isEmpty)
    }

    /// A commit made while the carry waits for the index (an agent's
    /// `git commit` holds the lock): going back to the old HEAD would undo
    /// it, so the source is left with it.
    @Test func aCommitMadeWhileTheIndexIsHeld_isKept() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("a\nB\nc\n", to: "a.txt", in: repo.url)
        try await repo.git(["add", "a.txt"])
        let target = try await Self.addTarget(repo, branch: "carried")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "HEAD", repoRoot: repo.url)
        // Another Git holds the index; meanwhile HEAD moves to a commit of
        // what is staged, which is how `git commit` leaves it.
        let tree = try await repo.git(["write-tree"])
        let commit = try await repo.git(["commit-tree", "-p", "HEAD", "-m", "agent", tree])
        let lock = repo.url.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        // HEAD moves only once the carry has found it unmoved, and before
        // it can hold the index: only the check under the lock sees it.
        let (checked, didCheck) = AsyncStream<Void>.makeStream()
        let moving = Task {
            let outcome = await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) {
                didCheck.yield()
            }
            didCheck.finish()
            return outcome
        }
        var checks = checked.makeAsyncIterator()
        #expect(await checks.next() != nil, "the carry reached its first check of HEAD")
        try await repo.git(["update-ref", "HEAD", commit])
        try FileManager.default.removeItem(at: lock)

        #expect(await moving.value == .leftInSource)
        #expect(try await repo.git(["rev-parse", "HEAD"]) == commit)
        #expect(try Self.read("a.txt", in: repo.url) == "a\nB\nc\n")
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty, "the commit holds the change, as it did")
    }

    /// A linked worktree is a source as the project's folder is: its index
    /// and its lock are in `.git/worktrees/<name>`.
    @Test func aLinkedWorktree_isASourceToo() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        let source = try await repo.addLinkedWorktree(branch: "source")
        try Self.write("linked\n", to: "a.txt", in: source)
        try Self.write("new\n", to: "notes.txt", in: source)
        let target = try await Self.addTarget(repo, branch: "carried", start: "source")
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: source))
        let placement = try await UncommittedChangesCarrier.place(snapshot, onto: "source", repoRoot: repo.url)

        #expect(await UncommittedChangesCarrier.move(snapshot, placement: placement, into: target) == .moved(files: 2))
        #expect(try Self.read("a.txt", in: target) == "linked\n")
        #expect(try Self.read("notes.txt", in: target) == "new\n")
        #expect(try await Self.status(source).isEmpty)
    }

    // MARK: - The stash stack

    /// A carry that moves the changes leaves the stash stack every worktree
    /// shares as it was.
    @Test func otherStashes_areLeftAsTheyWere() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try Self.write("someone else's\n", to: "a.txt", in: repo.url)
        try await repo.git(["stash", "push", "-q", "-m", "another-session"])
        let stashes = try await repo.git(["stash", "list", "--format=%H %gs"])
        try await Self.makeChanges(in: repo.url)
        let target = try await Self.addTarget(repo, branch: "carried")

        let (_, outcome) = try await Self.carry(repo, target: target)

        guard case .moved = outcome else {
            Issue.record("not moved: \(outcome)")
            return
        }
        #expect(try await repo.git(["stash", "list", "--format=%H %gs"]) == stashes)
    }

    /// The copy kept when the source cannot be cleared all the way is a
    /// stash entry `git stash apply --index` takes back exactly.
    @Test func theCopyKept_isAStashThatGivesTheChangesBack() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        try await Self.makeChanges(in: repo.url)
        let before = try await Self.state(repo.url)
        let snapshot = try #require(try await UncommittedChangesCarrier.snapshot(of: repo.url))

        let name = try #require(await UncommittedChangesCarrier.keepAsStash(snapshot))

        let entries = try await repo.git(["stash", "list", "--format=%gs"])
        #expect(entries.contains(name))
        try await repo.git(["reset", "-q", "--hard"])
        try await repo.git(["clean", "-q", "-f", "-d"])
        try await repo.git(["stash", "apply", "-q", "--index", "stash@{0}"])
        #expect(try await Self.state(repo.url) == before)
    }

    // MARK: - Counting

    @Test func theCount_isTheSidebars_aRenameOnce() async throws {
        let repo = try await Self.makeRepository()
        defer { repo.cleanup() }
        #expect(await UncommittedChangesCarrier.changedFileCount(in: repo.url) == 0)
        try await Self.makeChanges(in: repo.url)
        #expect(await UncommittedChangesCarrier.changedFileCount(in: repo.url) == 8)
    }
}
