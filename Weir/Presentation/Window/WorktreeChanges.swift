// WorktreeChanges.swift
// Weir — what changed outside every turn in each worktree, and the files each turn changed, counted once and shared.

import Foundation
import Observation
import WeirDomain

/// One owner per app for what each worktree's turns do not account for
/// and the files each turn changed: the changes panel and the
/// review tab read the same answer, and Git runs once for both.
///
/// The changes outside turns are those still uncommitted: changed in a gap
/// between turns, or since the last turn ended, and not committed since. A
/// pull, a merge, or a commit between turns is history, not something to
/// look at before a pull request. The two are matched by path: a
/// file changed and committed between turns, then changed again by a turn
/// and left uncommitted, is counted, which says too much rather than too
/// little. So is an untracked file over the hook's size limit, which no
/// snapshot holds.
///
/// What is fixed is kept, answered or not: a gap between two recorded
/// trees, and a turn's own files, never change, and a tree found gone
/// stays gone. What changed since the last turn, and what is uncommitted,
/// are asked each time. A count that does not finish keeps the one before.
/// A count once started runs to its end, the panel closing or not. While one
/// runs, the requests for the same worktree are merged into the latest, which
/// runs next: each would count the same worktree, and the latest knows the
/// most turns.
///
/// What is kept follows what still exists: a turn the retention sweep
/// deleted is forgotten (`forget(turns:)`), as are the gaps a count no longer
/// asks about and the worktrees no project holds now (`forgetRoots`), and
/// each kind of answer is capped, since all of it can be asked again.
@MainActor
@Observable
final class WorktreeChanges {
    /// How the owner asks Git; injected so a test can answer without a
    /// repository.
    struct Git: Sendable {
        var pathsBetween: @Sendable (URL, String, String) async throws -> Set<String>
        var pathsSince: @Sendable (URL, String, [String: ReviewGit.ContentFingerprint]) async throws -> ReviewGit.ChangedSince
        var uncommitted: @Sendable (URL) async throws -> Set<String>
        var fingerprints: @Sendable (URL, Set<String>, [String: ReviewGit.ContentFingerprint]) async throws
            -> [String: ReviewGit.ContentFingerprint]
        /// What changed between two trees, as the panel's totals count it
        /// (`ReviewGit.counts`). Finds nothing by default, for the stubs
        /// that count only paths.
        var counts: @Sendable (URL, String, String) async throws -> ChangeSummary = { _, _, _ in throw ReviewError.gitFailed }

        static let live = Git(
            pathsBetween: { root, earlier, later in try await ReviewGit.pathsChanged(from: earlier, to: later, at: root) },
            pathsSince: { root, tree, known in try await ReviewGit.pathsChanged(since: tree, at: root, known: known) },
            uncommitted: { root in try await ReviewGit.uncommittedPaths(at: root) },
            fingerprints: { root, paths, known in try await ReviewGit.contentFingerprints(of: paths, at: root, known: known) },
            counts: { root, earlier, later in try await ReviewGit.counts(from: earlier, to: later, root: root) }
        )

        /// Finds nothing changed, for demo mode: its worktrees are a
        /// fixture's, and Git is not asked. A turn's own files are not
        /// known (as for trees Git no longer has), so the panel keeps the
        /// turn's lines rather than say it changed no file.
        static let inert = inert(counts: nil)

        /// The same, with every comparison counted as `counts`: what the
        /// demo's staged turns changed altogether, so the panel's totals
        /// show (`DemoFixture.worktreeCounts`); `nil` leaves them unread.
        static func inert(counts: ChangeSummary?) -> Git {
            Git(
                pathsBetween: { _, _, _ in throw ReviewError.gitFailed },
                pathsSince: { _, _, _ in ReviewGit.ChangedSince(paths: []) },
                uncommitted: { _ in [] },
                fingerprints: { _, _, _ in [:] },
                counts: { _, _, _ in
                    guard let counts else { throw ReviewError.gitFailed }
                    return counts
                }
            )
        }
    }

    /// What is known of something fixed: its paths, or that Git could not
    /// read it (a tree the retention sweep deleted), which is not asked
    /// again.
    enum Known: Equatable, Sendable {
        case paths(Set<String>)
        case unknown
    }

    /// How many turns' files are kept at most; past it, those of the turns
    /// last asked about are what stays.
    static let maxTurnPaths = 5000
    /// How many comparisons are kept at most, the oldest dropped first.
    static let maxComparisons = 256
    /// How many worktrees' counts are kept at most, the one counted longest
    /// ago dropped first.
    static let maxRoots = 32

    /// Each worktree's paths changed outside every turn, by its top level;
    /// absent until counted once.
    private(set) var outsideTurns: [String: Set<String>] = [:]
    /// What each of those holds as counted (`ReviewGit.contentFingerprints`):
    /// what the review copies as it reads its list, to record on "Mark as
    /// Viewed" and to tell a viewed path changed since.
    private(set) var outsideTurnsContents: [String: [String: String]] = [:]
    /// The worktrees whose last count left a gap, or what changed since, out
    /// because the turns it starts from ended in one second at different
    /// trees (`OutsideTurnsPlan.isComplete`), or because a gap's tree is gone
    /// while an uncommitted path is not counted: their count may be short,
    /// which the panel says rather than let it read as the whole. With every
    /// uncommitted path counted, a gone gap could add nothing, as the count
    /// holds only those.
    private(set) var incompleteOutsideTurns: Set<String> = []
    /// The same with each file's size, time, and inode, so the next count
    /// hashes only what was touched.
    @ObservationIgnored private var fingerprints: [String: [String: ReviewGit.ContentFingerprint]] = [:]
    /// What each untracked file the last turn's tree held hashed to, so the
    /// next count hashes only what was touched (`ReviewGit.pathsChanged(since:)`).
    @ObservationIgnored private var untrackedHashes: [String: [String: ReviewGit.ContentFingerprint]] = [:]
    /// Each turn's own files, between its begin and its end.
    private(set) var turnPaths: [TurnID: Known] = [:]
    /// What changed between two recorded trees: the changes panel's totals
    /// over a worktree's turns, one comparison.
    private(set) var comparisons: [Comparison: KnownCounts] = [:]
    /// The comparisons in `comparisons`, oldest first.
    @ObservationIgnored private var comparisonOrder: [Comparison] = []
    /// By worktree, what each gap of its last count changed.
    @ObservationIgnored private var gapPaths: [String: [OutsideTurnsPlan.Gap: Known]] = [:]
    /// The worktrees counted, the one counted longest ago first.
    @ObservationIgnored private var countedRoots: [String] = []
    /// The run of counts for each worktree, which a request joins.
    @ObservationIgnored private var counting: [String: Task<Void, Never>] = [:]
    /// The latest request for each worktree not yet taken up by its run.
    @ObservationIgnored private var requested: [String: Request] = [:]
    @ObservationIgnored private let git: Git

    private struct Request {
        let root: URL
        let turns: [TurnSummary]
        let recorded: [ConversationKey: Set<Int>]?
        let deleted: [DateInterval]
    }

    init(git: Git = .live) {
        self.git = git
    }

    /// Counts again what changed outside every turn in `root`, with every
    /// agent's turns recorded there and, by conversation, the numbers of
    /// every turn recorded anywhere (`recorded`), which tell a gap across a
    /// deleted turn, and when the turns deleted here ran (`deleted`;
    /// `OutsideTurnsPlan.make`). Returns once a count that started after
    /// this request has ended: this one's, or a later one's that took its
    /// place.
    func refresh(
        root: URL,
        turns: [TurnSummary],
        recorded: [ConversationKey: Set<Int>]? = nil,
        deleted: [DateInterval] = []
    ) async {
        let key = root.path
        requested[key] = Request(root: root, turns: turns, recorded: recorded, deleted: deleted)
        if let running = counting[key] {
            await running.value
            return
        }
        let run = Task { [weak self] in
            guard let self else { return }
            await countRequests(of: key)
        }
        counting[key] = run
        await run.value
    }

    /// Counts the latest request for `key` until none is left. On the main
    /// actor, the run ends only once no request waits, so one made while
    /// it runs is always taken up.
    private func countRequests(of key: String) async {
        while let request = requested.removeValue(forKey: key) {
            await count(root: request.root, turns: request.turns, recorded: request.recorded, deleted: request.deleted)
        }
        counting[key] = nil
    }

    /// Reads the files of each turn that changed some, once; one whose
    /// trees are gone is kept as unknown. Written once at the end, so the
    /// panel draws once.
    func loadTurnPaths(_ turns: [TurnSummary], root: URL) async {
        var found: [TurnID: Known] = [:]
        for turn in turns where turnPaths[turn.turnID] == nil {
            guard case .changed = turn.changes, turn.phase != .started else { continue }
            guard let begin = turn.beginTree, let end = turn.endTree,
                  ReviewTurnRange.isTreeName(begin.tree), ReviewTurnRange.isTreeName(end.tree)
            else {
                found[turn.turnID] = .unknown
                continue
            }
            do {
                found[turn.turnID] = try await .paths(git.pathsBetween(root, begin.tree, end.tree))
            } catch ReviewError.gitFailed {
                found[turn.turnID] = .unknown
            } catch {
                // Git did not answer; the next look asks again.
                continue
            }
        }
        if !found.isEmpty {
            turnPaths.merge(found) { _, new in new }
            if turnPaths.count > Self.maxTurnPaths {
                let asked = Set(turns.map(\.turnID))
                turnPaths = turnPaths.filter { asked.contains($0.key) }
            }
        }
    }

    /// Forgets what was kept of turns the retention sweep deleted: their
    /// trees are gone, and no surface lists them again.
    func forget(turns: some Sequence<TurnID>) {
        let gone = turns.filter { turnPaths[$0] != nil }
        guard !gone.isEmpty else { return }
        for turn in gone {
            turnPaths[turn] = nil
        }
    }

    /// Forgets every worktree's count but those of `live`, the top levels
    /// the projects hold now: a project or worktree removed is not counted
    /// again, and what was counted of it is of no use.
    func forgetRoots(except live: Set<String>) {
        for root in countedRoots where !live.contains(root) {
            forgetRoot(root)
        }
    }

    private func forgetRoot(_ root: String) {
        countedRoots.removeAll { $0 == root }
        gapPaths[root] = nil
        fingerprints[root] = nil
        untrackedHashes[root] = nil
        if outsideTurns[root] != nil {
            outsideTurns[root] = nil
        }
        if outsideTurnsContents[root] != nil {
            outsideTurnsContents[root] = nil
        }
        if incompleteOutsideTurns.contains(root) {
            incompleteOutsideTurns.remove(root)
        }
    }

    /// Two recorded trees, compared as the panel's totals compare them:
    /// the worktree's unviewed range's (`ChangesPanelModel.comparison`).
    struct Comparison: Hashable, Sendable {
        let begin: String
        let end: String
    }

    /// What is known of a comparison: its counts, or that Git could not
    /// read it (a tree the retention sweep deleted), which is not asked
    /// again.
    enum KnownCounts: Equatable, Sendable {
        case counted(ChangeSummary)
        case unknown
    }

    /// Reads what changed between the trees of `comparison`, once; one
    /// whose trees are gone is kept as unknown. Both trees are fixed, so
    /// the answer is kept for as long as the app runs.
    func loadComparison(_ comparison: Comparison, root: URL) async {
        guard comparisons[comparison] == nil else { return }
        let known: KnownCounts
        do {
            known = try await .counted(git.counts(root, comparison.begin, comparison.end))
        } catch ReviewError.gitFailed {
            known = .unknown
        } catch {
            // Git did not answer; the next look asks again.
            return
        }
        // Asked twice at once: the first answer stands.
        guard comparisons[comparison] == nil else { return }
        comparisons[comparison] = known
        comparisonOrder.append(comparison)
        // The range moves with each mark, so the ones before it are read
        // again only when a mark is undone.
        if comparisonOrder.count > Self.maxComparisons {
            let dropped = comparisonOrder.count - Self.maxComparisons
            for old in comparisonOrder.prefix(dropped) {
                comparisons[old] = nil
            }
            comparisonOrder.removeFirst(dropped)
        }
    }

    /// What changed between the trees of `comparison`; `nil` while it has
    /// not been read, or cannot be.
    func counts(of comparison: Comparison) -> ChangeSummary? {
        guard case let .counted(counts)? = comparisons[comparison] else { return nil }
        return counts
    }

    /// The files `turn` changed between its begin and its end, as the
    /// review's file tags name them (`ReviewFileTags`); `nil` while they
    /// have not been read, or cannot be.
    func paths(of turn: TurnID) -> Set<String>? {
        guard case let .paths(own)? = turnPaths[turn] else { return nil }
        return own
    }

    /// Whether Git could not read the files `turn` changed (a tree the
    /// retention sweep deleted), which is not asked again: what the file
    /// tags' tooltip says they may lack.
    func isUnreadable(_ turn: TurnID) -> Bool {
        turnPaths[turn] == .unknown
    }

    private func count(
        root: URL,
        turns: [TurnSummary],
        recorded: [ConversationKey: Set<Int>]?,
        deleted: [DateInterval]
    ) async {
        // The turns are this worktree's already (`ChangesPanelModel.turnsHere`).
        let plan = OutsideTurnsPlan.make(
            turns: turns,
            isHere: { ReviewTurnRange.isTreeName($0.tree) },
            isRecorded: { conversation, number in recorded.map { $0[conversation]?.contains(number) ?? false } ?? true },
            deleted: deleted
        )
        let key = root.path
        noteCounted(key)
        // Only the gaps of this plan are kept: one across a turn deleted
        // since is not in it, and is not asked about again.
        let before = gapPaths[key] ?? [:]
        var kept: [OutsideTurnsPlan.Gap: Known] = [:]
        defer {
            // Unless the worktree was forgotten while Git ran.
            if countedRoots.contains(key) {
                gapPaths[key] = kept
            }
        }
        var paths: Set<String> = []
        var found: [String: ReviewGit.ContentFingerprint] = [:]
        var uncommitted: Set<String> = []
        do {
            for gap in plan.gaps {
                switch before[gap] ?? kept[gap] {
                case let .paths(known):
                    kept[gap] = .paths(known)
                    paths.formUnion(known)
                case .unknown:
                    kept[gap] = .unknown
                case nil:
                    do {
                        let found = try await git.pathsBetween(root, gap.end, gap.begin)
                        kept[gap] = .paths(found)
                        paths.formUnion(found)
                    } catch ReviewError.gitFailed {
                        kept[gap] = .unknown
                    }
                }
            }
            if let since = plan.since {
                let changed = try await git.pathsSince(root, since, untrackedHashes[key] ?? [:])
                paths.formUnion(changed.paths)
                // Only the files listed now: the rest are not asked again.
                if countedRoots.contains(key) {
                    untrackedHashes[key] = changed.untrackedHashes
                }
            }
            uncommitted = try await git.uncommitted(root)
            paths.formIntersection(uncommitted)
            // Nothing to hash when nothing changed outside turns.
            found = try await paths.isEmpty ? [:] : git.fingerprints(root, paths, fingerprints[root.path] ?? [:])
        } catch {
            // Git did not answer: the count before stands.
            return
        }
        // Forgotten while Git ran: the worktree is no project's now.
        guard countedRoots.contains(key) else { return }
        if outsideTurns[key] != paths {
            outsideTurns[key] = paths
        }
        let hasGoneGap = plan.gaps.contains { kept[$0] == .unknown }
        noteCompleteness(of: key, isComplete: plan.isComplete && (!hasGoneGap || uncommitted.isSubset(of: paths)))
        fingerprints[key] = found
        let contents = found.mapValues(\.contents)
        if outsideTurnsContents[key] != contents {
            outsideTurnsContents[key] = contents
        }
    }

    /// Marks `root`'s count short or whole, writing only a change, so the
    /// panel draws only then.
    private func noteCompleteness(of root: String, isComplete: Bool) {
        guard incompleteOutsideTurns.contains(root) == isComplete else { return }
        if isComplete {
            incompleteOutsideTurns.remove(root)
        } else {
            incompleteOutsideTurns.insert(root)
        }
    }

    /// Moves `root` to the end of the counted worktrees, dropping the one
    /// counted longest ago past `maxRoots`.
    private func noteCounted(_ root: String) {
        countedRoots.removeAll { $0 == root }
        countedRoots.append(root)
        while countedRoots.count > Self.maxRoots {
            forgetRoot(countedRoots[0])
        }
    }

    /// The paths of `contents` not viewed as they are there: never marked,
    /// or marked with other contents.
    nonisolated static func unviewed(_ contents: [String: String], viewed: [String: String]?) -> Set<String> {
        Set(contents.compactMap { path, now in viewed?[path] == now ? nil : path })
    }
}
