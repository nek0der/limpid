// WorktreeChangesTests.swift
// Limpid — one owner counting what each worktree's turns do not account for, keeping what never changes.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Worktree changes")
struct WorktreeChangesTests {
    /// A tree the retention sweep deleted.
    private nonisolated static let gone = TurnSummaryFixture.tree("d", 0)

    /// Git's answers, counted, with "since" able to fail on demand and to
    /// say whether two ran at once. Every path it names is uncommitted
    /// until `commit` says which stay.
    private actor GitStub {
        private(set) var betweenAsks: [String] = []
        private(set) var sinceAsks = 0
        private(set) var overlapped = false
        private var isSinceRunning = false
        private var named: Set<String> = []
        private var left: Set<String>?
        var sinceAnswer: Result<Set<String>, any Error> = .success(["later.swift"])

        func between(_ earlier: String, _ later: String) throws -> Set<String> {
            betweenAsks.append("\(earlier.prefix(1))..\(later.prefix(1))")
            if earlier == WorktreeChangesTests.gone || later == WorktreeChangesTests.gone {
                throw ReviewError.gitFailed
            }
            let paths: Set = ["\(earlier.prefix(1))-\(later.prefix(1)).swift", "shared.swift"]
            named.formUnion(paths)
            return paths
        }

        /// What "since" waits on before it answers, from `hold` until
        /// `release`; nil while it answers at once.
        private var held: Gate<Void>?

        func hold() {
            held = Gate()
        }

        func release() {
            held?.open()
            held = nil
        }

        /// Returns once a "since" waits at the gate `hold` set.
        func untilASinceIsHeld() async {
            await held?.waitUntilRequested()
        }

        func since() async throws -> Set<String> {
            sinceAsks += 1
            overlapped = overlapped || isSinceRunning
            isSinceRunning = true
            defer { isSinceRunning = false }
            await held?.wait()
            await Task.yield()
            let paths = try sinceAnswer.get()
            named.formUnion(paths)
            return paths
        }

        func uncommitted() -> Set<String> {
            left ?? named
        }

        func failSince(with error: any Error) {
            sinceAnswer = .failure(error)
        }

        func commit(leaving paths: Set<String>) {
            left = paths
        }

        /// Each path's contents, the same until `edit` changes one.
        private var edits: [String: Int] = [:]
        private(set) var fingerprintAsks: [Set<String>] = []
        /// What each ask was handed as known.
        private(set) var knownHanded: [[String: ReviewGit.ContentFingerprint]] = []
        var failsFingerprints = false

        func fingerprints(
            _ paths: Set<String>,
            known: [String: ReviewGit.ContentFingerprint]
        ) throws -> [String: ReviewGit.ContentFingerprint] {
            fingerprintAsks.append(paths)
            knownHanded.append(known)
            if failsFingerprints {
                throw ReviewError.timedOut
            }
            return Dictionary(uniqueKeysWithValues: paths.map {
                ($0, ReviewGit.ContentFingerprint(contents: "blob:\(edits[$0, default: 0])", stat: "\(edits[$0, default: 0])"))
            })
        }

        func failFingerprints() {
            failsFingerprints = true
        }

        func edit(_ path: String) {
            edits[path, default: 0] += 1
        }
    }

    private static let root = URL(fileURLWithPath: "/repo")

    private static func owner(_ git: GitStub) -> WorktreeChanges {
        WorktreeChanges(git: WorktreeChanges.Git(
            pathsBetween: { _, earlier, later in try await git.between(earlier, later) },
            pathsSince: { _, _, _ in try await ReviewGit.ChangedSince(paths: git.since()) },
            uncommitted: { _ in await git.uncommitted() },
            fingerprints: { _, paths, known in try await git.fingerprints(paths, known: known) }
        ))
    }

    /// Turn `number`, begun at tree `b…`, ended at `e…` unless given.
    private static func turn(
        _ number: Int,
        start: Int,
        end: Int,
        endTree: String? = nil,
        conversation: String = "s1",
        changes: String = TurnSummaryFixture.changedFiles
    ) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = conversation
        extras.startedAt = String(format: "2026-10-12T00:%02d:00Z", start)
        extras.finishedAt = String(format: "2026-10-12T00:%02d:00Z", end)
        extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("b", number), root: "/repo")
        return try TurnSummaryFixture.turn(
            "T\(number)",
            changes: changes,
            number: number,
            endTree: SnapshotTree(tree: endTree ?? TurnSummaryFixture.tree("e", number), root: "/repo"),
            extras: extras
        )
    }

    @Test func aGapIsAskedOnce_andWhatChangedSince_eachTime() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]

        await owner.refresh(root: Self.root, turns: turns)
        await owner.refresh(root: Self.root, turns: turns)

        #expect(await git.betweenAsks == ["e..b"], "a gap between two fixed trees never changes")
        #expect(await git.sinceAsks == 2)
        #expect(owner.outsideTurns["/repo"] == ["e-b.swift", "shared.swift", "later.swift"])
    }

    @Test func twoAgentsEndingInOneSecond_atOtherTrees_markTheCountIncomplete_untilCountedWhole() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let tied = try [
            Self.turn(1, start: 0, end: 10),
            Self.turn(2, start: 5, end: 10, conversation: "s2")
        ]

        await owner.refresh(root: Self.root, turns: tied)

        #expect(owner.outsideTurns["/repo"] == [], "which tree was left last is not known, so nothing since is counted")
        #expect(owner.incompleteOutsideTurns.contains("/repo"), "the panel says the count may be short")

        // The other agent's turn deleted: one end, in order.
        await owner.refresh(root: Self.root, turns: [tied[0]])

        #expect(owner.outsideTurns["/repo"] == ["later.swift"])
        #expect(!owner.incompleteOutsideTurns.contains("/repo"), "a whole count clears the mark")

        await owner.refresh(root: Self.root, turns: tied)
        owner.forgetRoots(except: [])
        #expect(!owner.incompleteOutsideTurns.contains("/repo"), "a forgotten worktree says nothing")
    }

    @Test func aPathChangedInTwoGaps_isCountedOnce() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30), Self.turn(3, start: 40, end: 50)]

        await owner.refresh(root: Self.root, turns: turns)

        #expect(await git.betweenAsks.count == 2)
        #expect(owner.outsideTurns["/repo"]?.count == 3, "e-b.swift, shared.swift, later.swift")
    }

    @Test func aGoneGap_isRememberedAsUnknown_andNotAskedAgain() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10, endTree: Self.gone), Self.turn(2, start: 20, end: 30)]

        await owner.refresh(root: Self.root, turns: turns)
        await owner.refresh(root: Self.root, turns: turns)

        #expect(await git.betweenAsks.count == 1, "a tree the sweep deleted stays deleted")
        #expect(owner.outsideTurns["/repo"] == ["later.swift"], "what is unknown adds nothing")
    }

    @Test func whatWasCommittedSince_isNotOutsideTurns() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]
        await owner.refresh(root: Self.root, turns: turns)
        #expect(owner.outsideTurns["/repo"]?.contains("e-b.swift") == true)

        // The person committed everything but the file edited since.
        await git.commit(leaving: ["later.swift"])
        await owner.refresh(root: Self.root, turns: turns)

        #expect(owner.outsideTurns["/repo"] == ["later.swift"])
    }

    @Test func aCountThatDoesNotFinish_keepsTheOneBefore() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]
        await owner.refresh(root: Self.root, turns: turns)
        let before = owner.outsideTurns["/repo"]

        await git.failSince(with: ReviewError.timedOut)
        await owner.refresh(root: Self.root, turns: turns)
        #expect(owner.outsideTurns["/repo"] == before, "a failure to count is not none")

        await git.failSince(with: CancellationError())
        await owner.refresh(root: Self.root, turns: turns)
        #expect(owner.outsideTurns["/repo"] == before)
    }

    /// Requests made while a count runs are merged into the latest, so ten
    /// asked during a slow count make one count more, never two at once.
    @Test func requestsWhileACountRuns_areMergedIntoTheLatest() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        await git.hold()
        let one = try [Self.turn(1, start: 0, end: 10)]
        let two = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]

        let running = Task { await owner.refresh(root: Self.root, turns: one) }
        await git.untilASinceIsHeld()
        #expect(await git.sinceAsks == 1, "the first count is under way")
        let waiting = (0..<10).map { index in
            Task { await owner.refresh(root: Self.root, turns: index == 9 ? two : one) }
        }
        // Each request is taken in as its task starts, before it waits, so
        // the tasks only have to have started: the main actor runs its jobs
        // in the order they were queued, theirs before this one.
        await Task { @MainActor in }.value
        await git.release()
        await running.value
        for task in waiting {
            await task.value
        }

        #expect(await git.sinceAsks == 2, "one count running, then the latest request")
        #expect(await git.betweenAsks == ["e..b"], "the latest request's turns, with its gap")
        #expect(await !git.overlapped)
    }

    // MARK: - What is kept

    /// A gap across a turn deleted since is no longer in the plan, and is
    /// not kept: asked again only if the turn came back.
    @Test func aGapNoLongerCounted_isForgotten() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let both = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]

        await owner.refresh(root: Self.root, turns: both)
        await owner.refresh(root: Self.root, turns: [both[1]])
        await owner.refresh(root: Self.root, turns: both)

        #expect(await git.betweenAsks == ["e..b", "e..b"])
    }

    @Test func aDeletedTurnsFiles_areForgotten() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turn = try Self.turn(1, start: 0, end: 10)
        await owner.loadTurnPaths([turn], root: Self.root)
        #expect(owner.paths(of: turn.turnID) != nil)

        owner.forget(turns: [turn.turnID])

        #expect(owner.paths(of: turn.turnID) == nil)
        #expect(!owner.isUnreadable(turn.turnID))
    }

    @Test func aWorktreeNoProjectHolds_isForgotten() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10)]
        let other = URL(fileURLWithPath: "/other")
        await owner.refresh(root: Self.root, turns: turns)
        await owner.refresh(root: other, turns: turns)

        owner.forgetRoots(except: ["/other"])

        #expect(owner.outsideTurns["/repo"] == nil)
        #expect(owner.outsideTurnsContents["/repo"] == nil)
        #expect(owner.outsideTurns["/other"] != nil)
    }

    @Test func theWorktreeCountedLongestAgo_isDroppedPastTheCap() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10)]
        for index in 0...WorktreeChanges.maxRoots {
            await owner.refresh(root: URL(fileURLWithPath: "/repo\(index)"), turns: turns)
        }

        #expect(owner.outsideTurns.count == WorktreeChanges.maxRoots)
        #expect(owner.outsideTurns["/repo0"] == nil)
        #expect(owner.outsideTurns["/repo\(WorktreeChanges.maxRoots)"] != nil)
    }

    @Test func theOldestComparison_isDroppedPastTheCap() async {
        let owner = WorktreeChanges(git: WorktreeChanges.Git(
            pathsBetween: { _, _, _ in [] },
            pathsSince: { _, _, _ in ReviewGit.ChangedSince(paths: []) },
            uncommitted: { _ in [] },
            fingerprints: { _, _, _ in [:] },
            counts: { _, _, _ in .changed(files: 1, added: 1, removed: 0) }
        ))
        let comparisons = (0...WorktreeChanges.maxComparisons).map { index in
            WorktreeChanges.Comparison(begin: TurnSummaryFixture.tree("b", index), end: TurnSummaryFixture.tree("e", index))
        }
        for comparison in comparisons {
            await owner.loadComparison(comparison, root: Self.root)
        }

        #expect(owner.comparisons.count == WorktreeChanges.maxComparisons)
        #expect(owner.counts(of: comparisons[0]) == nil)
        #expect(owner.counts(of: comparisons[WorktreeChanges.maxComparisons]) != nil)
    }

    @Test func eachTurnsFiles_areReadOnce() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]

        #expect(owner.paths(of: turns[0].turnID) == nil, "not read yet")
        await owner.loadTurnPaths(turns, root: Self.root)
        let paths = turns.compactMap { owner.paths(of: $0.turnID) }
        #expect(paths.count == 2)
        #expect(paths.reduce(into: Set<String>()) { $0.formUnion($1) }.count == 2, "b-e.swift and shared.swift")
        await owner.loadTurnPaths(turns, root: Self.root)
        #expect(await git.betweenAsks.count == 2, "each turn's files read once")
    }

    /// The panel's totals are one comparison between two trees: read once,
    /// kept, and unknown for a tree Git no longer has.
    @Test func aComparison_isCountedOnce_andAGoneTreeIsUnknown() async {
        let asks = Asks()
        let owner = WorktreeChanges(git: WorktreeChanges.Git(
            pathsBetween: { _, _, _ in [] },
            pathsSince: { _, _, _ in ReviewGit.ChangedSince(paths: []) },
            uncommitted: { _ in [] },
            fingerprints: { _, _, _ in [:] },
            counts: { _, earlier, later in
                await asks.note("\(earlier.prefix(1))..\(later.prefix(1))")
                if later == WorktreeChangesTests.gone {
                    throw ReviewError.gitFailed
                }
                return .changed(files: 2, added: 5, removed: 1)
            }
        ))
        let comparison = WorktreeChanges.Comparison(begin: TurnSummaryFixture.tree("b", 1), end: TurnSummaryFixture.tree("e", 2))
        let lost = WorktreeChanges.Comparison(begin: TurnSummaryFixture.tree("b", 1), end: Self.gone)

        #expect(owner.counts(of: comparison) == nil, "not read yet")
        await owner.loadComparison(comparison, root: Self.root)
        await owner.loadComparison(comparison, root: Self.root)
        await owner.loadComparison(lost, root: Self.root)
        await owner.loadComparison(lost, root: Self.root)

        #expect(owner.counts(of: comparison) == .changed(files: 2, added: 5, removed: 1))
        #expect(owner.counts(of: lost) == nil)
        #expect(await asks.noted == ["b..e", "b..d"], "each comparison asked once, a gone tree too")
    }

    private actor Asks {
        private(set) var noted: [String] = []

        func note(_ ask: String) {
            noted.append(ask)
        }
    }

    @Test func aTurnWithoutItsTrees_isUnreadable_andNotAskedAgain() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let kept = try Self.turn(1, start: 0, end: 10)
        let gone = try Self.turn(2, start: 20, end: 30, endTree: Self.gone)
        let answerOnly = try Self.turn(3, start: 40, end: 50, changes: #"{"kind":"unchanged"}"#)

        await owner.loadTurnPaths([kept, gone, answerOnly], root: Self.root)

        #expect(owner.paths(of: kept.turnID) != nil)
        #expect(owner.paths(of: gone.turnID) == nil && owner.isUnreadable(gone.turnID))
        #expect(!owner.isUnreadable(answerOnly.turnID), "a turn that changed nothing is not asked")
        await owner.loadTurnPaths([gone], root: Self.root)
        #expect(await git.betweenAsks.count == 2, "a gone tree is not asked again")
    }

    @Test func aChangeOutsideTurns_isUnviewedUntilViewed_andAgainOnceEdited() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10)]
        await owner.refresh(root: Self.root, turns: turns)
        let contents = try #require(owner.outsideTurnsContents["/repo"])
        #expect(WorktreeChanges.unviewed(contents, viewed: nil) == ["later.swift"])
        #expect(WorktreeChanges.unviewed(contents, viewed: contents).isEmpty)

        await git.edit("later.swift")
        await owner.refresh(root: Self.root, turns: turns)
        #expect(
            try WorktreeChanges.unviewed(#require(owner.outsideTurnsContents["/repo"]), viewed: contents) == ["later.swift"],
            "what was viewed is the contents then"
        )
        #expect(
            await git.knownHanded.last?["later.swift"]?.contents == "blob:0",
            "what was hashed is handed back, to hash only what was touched"
        )
    }

    @Test func contentsThatCannotBeRead_keepTheCountBefore() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        let turns = try [Self.turn(1, start: 0, end: 10), Self.turn(2, start: 20, end: 30)]
        await owner.refresh(root: Self.root, turns: turns)
        let count = owner.outsideTurns["/repo"]
        let contents = owner.outsideTurnsContents["/repo"]
        #expect(count?.count == 3)

        await git.commit(leaving: ["later.swift"])
        await git.failFingerprints()
        await owner.refresh(root: Self.root, turns: turns)
        #expect(owner.outsideTurns["/repo"] == count, "the paths with no contents to go with them are not taken")
        #expect(owner.outsideTurnsContents["/repo"] == contents)
    }

    @Test func nothingOutsideTurns_asksForNoContents() async throws {
        let git = GitStub()
        let owner = Self.owner(git)
        await git.commit(leaving: [])

        try await owner.refresh(root: Self.root, turns: [Self.turn(1, start: 0, end: 10)])

        #expect(owner.outsideTurns["/repo"] == [])
        #expect(await git.fingerprintAsks.isEmpty)
    }
}
