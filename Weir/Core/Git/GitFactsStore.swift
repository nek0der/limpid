// GitFactsStore.swift
// Weir — each session folder's Git facts, read again while Weir is in front.

import Foundation
import Observation

/// One owner for every session's `GitFacts`: the session header,
/// the sidebar rows, and the changes panel read the same answer.
///
/// No file event announces an edit in a work tree, so the facts are read
/// again on a clock, and only while Weir is in front, where someone
/// reads them: the sessions in front (each window's) every
/// `activeInterval`, the others every `allInterval` (the other worktrees at
/// most every `occasionalInterval`), and all of them as
/// Weir comes to the front (`appActivityChanged`, which the app calls).
/// A reading of all of them reads the sessions in front first and stops
/// if Weir goes to the back; one asked for while another runs runs once
/// after it, since the one running may have passed the folders that
/// changed.
///
/// Each folder is read once at a time; a read asked for meanwhile runs
/// after it. A reading Git did not answer keeps the facts before it, as a
/// count that does not finish does in `WorktreeChanges`, and the folder is
/// asked again only after a wait that grows with each such reading: a
/// repository too large to read in time would otherwise run Git into its
/// limit every few seconds.
///
/// Made with `staged` facts (demo mode, which the app decides), the store
/// holds those and nothing else: it starts no clock and asks Git nothing,
/// so a reading anyone asks for answers with what is staged.
@MainActor
@Observable
final class GitFactsStore {
    /// Absent until read once, and for a folder that is not a work tree.
    private(set) var facts: [ContainerID: GitFacts] = [:]

    /// The readings in a row Git did not answer, and when to ask again.
    private struct Backoff {
        let failures: Int
        let retryAt: ContinuousClock.Instant
    }

    @ObservationIgnored private let fetch: @Sendable (URL) async -> GitFactsRead
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    /// Whether the facts were handed in at `init` and are never read from
    /// Git: the demo's folders do not exist, and its scene has to show the
    /// same chips on every run.
    @ObservationIgnored private let isStaged: Bool
    @ObservationIgnored private var reading: [ContainerID: Task<Void, Never>] = [:]
    @ObservationIgnored private var backoff: [ContainerID: Backoff] = [:]
    /// When each of the other worktrees was last read, which paces them.
    @ObservationIgnored private var occasionalReadAt: [ContainerID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The session whose folders are read; `nil` until `start`.
    @ObservationIgnored private weak var session: WorkspaceSession?
    /// Whether Weir is in front; `nil` until `start`, when nothing stops
    /// a reading of all folders early.
    @ObservationIgnored private var isActive: (@MainActor () -> Bool)?
    /// What `appActivityChanged` heard last, so only coming to the front
    /// reads, not every change the app reports alongside it.
    @ObservationIgnored private var wasActive = false
    @ObservationIgnored private var isReadingAll = false
    /// A reading of all folders was asked for while one ran.
    @ObservationIgnored private var isAllPending = false

    static let activeInterval: Duration = .seconds(10)
    /// A multiple of `activeInterval`, which the loop counts in.
    static let allInterval: Duration = .seconds(30)
    /// The wait after the first unanswered reading, doubled for each after
    /// it up to `retryLimit`.
    static let retryBase: Duration = .seconds(30)
    static let retryLimit: Duration = .seconds(300)
    /// The least time between two readings of one of the other worktrees,
    /// as the pull request syncer paces them (`PRStatusSyncer.occasionalInterval`).
    static let occasionalInterval: Duration = .seconds(PRStatusSyncer.occasionalInterval)

    init(
        fetch: @escaping @Sendable (URL) async -> GitFactsRead = { await ReviewGit.facts(at: $0) },
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        staged: [ContainerID: GitFacts]? = nil
    ) {
        self.fetch = fetch
        self.now = now
        isStaged = staged != nil
        facts = staged ?? [:]
    }

    func facts(for container: ContainerID) -> GitFacts? {
        facts[container]
    }

    /// Starts reading `session`'s folders: the rows the pull request
    /// syncer reads (`PRStatusSyncer.enumerableTargets`). `isActive` is
    /// whether Weir is in front.
    func start(session: WorkspaceSession, isActive: @escaping @MainActor () -> Bool) {
        // Staged facts are the whole truth: there is nothing to read again.
        guard !isStaged, loop == nil else { return }
        self.session = session
        self.isActive = isActive
        // Launched from Finder or `open`, Weir can be in front already
        // as this runs, and no coming to the front follows: that reading
        // happens here. Either way the clock's first turn finds the facts
        // read.
        appActivityChanged(isActive: isActive())
        // The clock waits its interval first: the reading above, or the
        // one as Weir comes to the front, reads everything already.
        loop = Task { [weak self, weak session] in
            var tick = 1
            while !Task.isCancelled {
                try? await Task.sleep(for: GitFactsStore.activeInterval)
                // Held for the reading alone, so the sleep holds neither;
                // the loop ends with either.
                guard let hasRead = await self?.readIfActive(tick: tick, session: session) else { return }
                if hasRead {
                    tick += 1
                }
            }
        }
    }

    /// One turn of the clock: every folder on every `allInterval`, else the
    /// sessions in front (each window's). `nil` once the session is gone,
    /// else whether it read.
    private func readIfActive(tick: Int, session: WorkspaceSession?) async -> Bool? {
        guard let session else { return nil }
        guard isActive?() ?? false else { return false }
        let targets = PRStatusSyncer.enumerableTargets(session: session)
        // The sessions in front are those of every window, not only one.
        let shown = session.shownContainerIDs
        if tick.isMultiple(of: Int(Self.allInterval / Self.activeInterval)) {
            await refresh(targets, isAll: true, first: shown)
        } else {
            await refresh(targets.filter { shown.contains($0.container) })
        }
        return true
    }

    /// Every folder at once as Weir comes to the front: what changed
    /// while it was in the background shows without waiting for the
    /// clock. Nothing before `start`.
    func appActivityChanged(isActive: Bool) {
        defer { wasActive = isActive }
        guard isActive, !wasActive, let session else { return }
        Task { await refresh(PRStatusSyncer.enumerableTargets(session: session), isAll: true, first: session.shownContainerIDs) }
    }

    /// Reads `targets` again, `first` before the others. A reading of all
    /// of them also forgets the folders no longer among them; asked for
    /// while another runs, it runs once after that one.
    func refresh(_ targets: [PRStatusSyncer.Target], isAll: Bool = false, first: Set<ContainerID> = []) async {
        // A reading of all would also forget the staged folders it was not
        // handed.
        guard !isStaged else { return }
        guard isAll else {
            await read(targets, first: first, isAll: false)
            return
        }
        guard !isReadingAll else {
            isAllPending = true
            return
        }
        isReadingAll = true
        defer { isReadingAll = false }
        var targets = targets
        var first = first
        while true {
            isAllPending = false
            // Only what was known before the reading: a session added
            // while it ran is not one it missed.
            let gone = Set(facts.keys).union(backoff.keys).subtracting(targets.map(\.container))
            await read(targets, first: first, isAll: true)
            for container in gone {
                facts.removeValue(forKey: container)
                backoff.removeValue(forKey: container)
                occasionalReadAt.removeValue(forKey: container)
            }
            guard isAllPending else { return }
            // The folders as they are now, not as they were when the
            // reading was asked for.
            if let session {
                targets = PRStatusSyncer.enumerableTargets(session: session)
                first = session.shownContainerIDs
            }
        }
    }

    private func read(_ targets: [PRStatusSyncer.Target], first: Set<ContainerID>, isAll: Bool) async {
        let ordered = targets.filter { first.contains($0.container) } + targets.filter { !first.contains($0.container) }
        for target in ordered {
            // Only while someone can read the facts (`start`).
            if isAll, let isActive, !isActive() {
                return
            }
            // One of the other worktrees at most every `occasionalInterval`,
            // unless a window shows it (`PRStatusSyncer.Target.isOccasional`).
            if target.isOccasional, !first.contains(target.container) {
                if let last = occasionalReadAt[target.container], now() - last < Self.occasionalInterval {
                    continue
                }
                occasionalReadAt[target.container] = now()
            }
            await refresh(target.container, at: target.workingDirectory)
        }
    }

    /// Reads one folder again, after the reading under way for it, unless
    /// Git left it unanswered a moment ago, as the reading before may have.
    func refresh(_ container: ContainerID, at folder: URL) async {
        guard !isStaged, !isWaiting(container) else { return }
        let before = reading[container]
        let task = Task { [weak self, fetch] in
            await before?.value
            guard self?.isWaiting(container) == false else { return }
            let read = await fetch(folder)
            self?.apply(read, to: container)
        }
        reading[container] = task
        await task.value
        if reading[container] == task {
            reading.removeValue(forKey: container)
        }
    }

    /// Reads one folder now, whatever the wait, and returns what Git said:
    /// for a move the person asked for, which must not decide on facts
    /// older than the moment, such as removing a worktree.
    func read(_ container: ContainerID, at folder: URL) async -> GitFactsRead {
        if isStaged {
            return facts[container].map(GitFactsRead.facts) ?? .notWorkTree
        }
        let before = reading[container]
        let task = Task { [weak self, fetch] in
            await before?.value
            let read = await fetch(folder)
            self?.apply(read, to: container)
            return read
        }
        // Readings after this one wait for it, as they do for any other.
        let waiter = Task { _ = await task.value }
        reading[container] = waiter
        let read = await task.value
        if reading[container] == waiter {
            reading.removeValue(forKey: container)
        }
        return read
    }

    private func isWaiting(_ container: ContainerID) -> Bool {
        backoff[container].map { now() < $0.retryAt } ?? false
    }

    private func apply(_ read: GitFactsRead, to container: ContainerID) {
        switch read {
        case let .facts(read):
            backoff.removeValue(forKey: container)
            if facts[container] != read {
                facts[container] = read
            }
        case .notWorkTree:
            backoff.removeValue(forKey: container)
            // Written only when there was something: a write tells every
            // view reading the facts, every few seconds for such a folder.
            if facts[container] != nil {
                facts.removeValue(forKey: container)
            }
        case .unanswered:
            let failures = (backoff[container]?.failures ?? 0) + 1
            let wait = min(Self.retryBase * (1 << min(failures - 1, 8)), Self.retryLimit)
            backoff[container] = Backoff(failures: failures, retryAt: now() + wait)
        }
    }
}
