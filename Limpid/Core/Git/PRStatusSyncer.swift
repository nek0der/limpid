// PRStatusSyncer.swift
// Limpid — schedules forge CLI lookups per container and writes the
// results into `PRStatusStore`. Sibling to `GitSyncCoordinator` but
// kept deliberately separate because:
//   - `gh` / `glab` are optional dependencies; a failure here must
//     never poison local `git` sync.
//   - Pull-request state moves on the forge's clock, not the local
//     repo's, so the cadence is time-driven rather than mutation-driven,
//     with a lookup when an agent's turn ends (`TurnEndPRRefresh`), which
//     is often what moved it.
//   - It has no setting: pull requests show wherever `gh`
//     or `glab` can read them, and a CLI that is absent or signed out is
//     found out by the lookup itself.
//
// Lifecycle:
//   - `init` takes every collaborator, and where the requests come from
//     (`PRStatusSource`), rather than reaching for the session, the
//     store, or the demo flag through a global.
//   - `start()` arms a focus observer and a recurring task for the forge
//     CLIs; a fixture is written to the store once and nothing is
//     scheduled.

import AppKit
import Foundation
import OSLog

private let log = Logger.limpid("git.pr.sync")

/// Where `PRStatusSyncer` learns each row's request. The app chooses it
/// at launch (`AppState`), so the syncer reads no demo flag itself.
enum PRStatusSource {
    /// Asks the forge CLI for each row, on the syncer's cadence. The
    /// syncer builds its fetcher from these two, so the resolver a manual
    /// refresh invalidates is always the one its lookups read.
    case forgeCLI(resolver: ForgeResolver, locator: ToolLocator)
    /// Shows these requests and asks nothing, for demo mode: the hero
    /// screenshot has to look the same on every contributor's Mac, and a
    /// CLI answers from whatever is on disk under whatever credentials
    /// happen to be present. No forge is recorded either, as for a folder
    /// whose CLI is not installed.
    case fixture([ContainerID: PRInfo])

    /// The forge CLIs, found through `locator`.
    static func live(locator: ToolLocator) -> PRStatusSource {
        .forgeCLI(resolver: ForgeResolver(locator: locator), locator: locator)
    }
}

@MainActor
final class PRStatusSyncer {
    private weak var session: WorkspaceSession?
    private weak var store: PRStatusStore?

    /// A fixture's requests, written once by `start()`. `nil` for the
    /// forge CLIs, which `fetcher` asks instead.
    private let fixture: [ContainerID: PRInfo]?
    /// Built from the source's resolver and locator. Optional because a
    /// fixture asks no CLI, so it has nothing to fetch with.
    private let fetcher: (any PRStatusLookups)?
    /// What the new worktree sheet reads a pull request with, on the
    /// same resolver and locator, so the sheet and the marks agree on the
    /// forge and a manual refresh resets both. `nil` for a fixture, which
    /// asks no CLI.
    let pullRequests: (any PullRequestReading)?

    /// How long a row waits between recurring lookups, from what its last
    /// one found; `nil` for a row the recurring lookups leave alone. Every
    /// lookup costs one CLI spawn, so only what can still change soon is
    /// asked often:
    ///
    /// - Checks running: a run that finishes in a couple of minutes should
    ///   not read as running well after it stopped.
    /// - An open request: it is what a merge moves to Ready to Clean Up.
    /// - No request: one may be opened, which matters less soon.
    /// - A merged or closed request: nothing is left to wait for. Coming back
    ///   to the app and a turn's end still look it up, which is how a reopened
    ///   one is found.
    static func recurringInterval(for info: PRInfo?) -> TimeInterval? {
        guard let info else { return noRequestInterval }
        guard info.state == .open else { return nil }
        return info.checks?.conclusion == .pending ? pollInterval : openRequestInterval
    }

    private static let openRequestInterval: TimeInterval = 90
    private static let noRequestInterval: TimeInterval = 300

    /// Per-container floor between focus-driven fetches, so rapid app
    /// switching cannot issue one CLI call per row per switch.
    /// `refreshNow` deliberately ignores it — see there.
    private let perContainerMinInterval: TimeInterval = 60

    /// Last attempted fetch time per container. We track attempts
    /// (not just successes) so the floor still applies when the CLI
    /// fails — otherwise an offline user with rapid focus churn would
    /// spawn a process per row per alt-tab.
    private var lastFetchAt: [ContainerID: Date] = [:]

    /// The containers with a lookup running, and whether another was asked
    /// for while it ran. At most one runs per container: the triggers start
    /// independently, and two lookups of one row in flight could answer in
    /// either order, a slow earlier one putting back the CI state a later
    /// one had replaced. A request that finds one running asks for one
    /// lookup after it rather than its own, since the running one may have
    /// asked before whatever the request is about (a push, a merge).
    private var inFlight: [ContainerID: FollowUp] = [:]

    /// What was asked of a running lookup's container while it ran.
    private struct FollowUp {
        var isRequested = false
        /// Whether a manual refresh asked for it, which re-reads the forge.
        var invalidatesForges = false
    }

    /// The token of each container's latest lookup, taken from
    /// `nextLookupToken`. An answer is kept only while its token is still
    /// the container's: dropping a container drops its token, so an
    /// answer that lands after a prune cannot put the row back, even if a
    /// row with the same identity has come back since.
    private var lookupTokens: [ContainerID: UInt64] = [:]
    private var nextLookupToken: UInt64 = 0

    /// The branch each kept answer was asked for. The store keys a request
    /// by the row alone, and a checkout switched to another branch keeps
    /// its row, so this is what tells the previous branch's request from
    /// the current one's (`recheckLeftBranches`).
    private var answeredHeads: [ContainerID: CheckoutHead] = [:]

    /// Rows whose answer named another branch than the row shows, with the
    /// branch the row showed then. The fetcher already gives no answer for a
    /// checkout that switched while it ran, so a mismatch means Git has not
    /// been read again for the row since its checkout moved; asking again
    /// before it is would get the same mismatch. A wake looks such a row up
    /// only once the branch it shows has changed (`recheckLeftBranches`).
    private var leftBranches: [ContainerID: CheckoutHead] = [:]

    private var recurringTask: Task<Void, Never>?

    /// How often the recurring task wakes to reconsider, the shortest
    /// `recurringInterval`: waking more often would decide nothing sooner.
    private static let pollInterval: TimeInterval = 45
    private static let pollGranularity: Duration = .seconds(pollInterval)

    /// AppKit observer token. Held with `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can remove it; every mutation site
    /// (`observeFocus`) runs on @MainActor, so the unsafety is only
    /// paid at teardown — same posture as `GitSyncCoordinator`.
    private nonisolated(unsafe) var focusObserver: (any NSObjectProtocol)?

    convenience init(
        session: WorkspaceSession,
        store: PRStatusStore,
        source: PRStatusSource
    ) {
        switch source {
        case let .forgeCLI(resolver, locator):
            self.init(
                session: session,
                store: store,
                fetcher: PRStatusFetcher(resolver: resolver, locator: locator),
                pullRequests: ForgePullRequests(resolver: resolver, locator: locator)
            )
        case let .fixture(requests):
            self.init(session: session, store: store, fetcher: nil, pullRequests: nil, fixture: requests)
        }
    }

    /// Takes the fetcher itself, for the tests that script its answers.
    init(
        session: WorkspaceSession,
        store: PRStatusStore,
        fetcher: (any PRStatusLookups)?,
        pullRequests: (any PullRequestReading)? = nil,
        fixture: [ContainerID: PRInfo]? = nil
    ) {
        self.session = session
        self.store = store
        self.fetcher = fetcher
        self.pullRequests = pullRequests
        self.fixture = fixture
    }

    deinit {
        if let f = focusObserver {
            NotificationCenter.default.removeObserver(f)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // A fixture is the whole truth and never reaches a CLI, so
        // nothing is scheduled to refetch it.
        if let requests = fixture {
            for (container, info) in requests {
                store?.update(container: container, info: info)
            }
            return
        }
        observeFocus()
        scheduleRecurring()
        // start() runs on @MainActor, so the implicit Task isolation
        // is also @MainActor — no need to re-annotate.
        Task { [weak self] in
            await self?.tick(reason: .initial)
        }
    }

    // MARK: - Triggers

    private func observeFocus() {
        // The user often comes back to Limpid expecting "what I did
        // outside is reflected" — pushing a PR, merging it on the web,
        // approving a review. didBecomeActive is a cheap signal that
        // covers all three. The callback runs on the main queue so the
        // assumeIsolated wrapper lets us spawn a Task that inherits
        // MainActor without the compiler-ambiguous `@MainActor in`
        // capture form.
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tick(reason: .focus) }
            }
        }
    }

    /// Wake on a fixed granularity and let each row decide whether it is
    /// due (`isDue`), rather than sleeping for one interval: rows differ, and
    /// a row's interval moves as its request does. A wake looks up only the
    /// rows that are due, so waking often costs no CLI.
    private func scheduleRecurring() {
        recurringTask?.cancel()
        recurringTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollGranularity)
                // `self` is only reached after the sleep so the task
                // does not hold the syncer alive across it.
                guard !Task.isCancelled, let self else { return }
                // A request shown for a branch the checkout has left is
                // wrong, not just old.
                await recheckLeftBranches()
                await tick(reason: .recurring)
            }
        }
    }

    // MARK: - Tick

    private enum Reason: String {
        case initial
        case recurring
        case focus
    }

    private func tick(reason: Reason) async {
        guard let session, fetcher != nil else { return }
        let now = Date()
        let targets = Self.enumerableTargets(session: session)
        var attempted = 0
        for target in targets {
            // The floor is for the one trigger whose rate the user
            // sets: alt-tabbing back. The others pace themselves —
            // `.recurring` *is* the pace, and `.initial` runs once.
            //
            // Flooring `.recurring` would also slow a row with checks
            // running: 45s rounds against a 60s floor refetch every 90s,
            // watching a CI run at half the rate `recurringInterval` gives.
            if reason == .focus, !shouldFetch(container: target.container, now: now) {
                continue
            }
            if reason == .recurring, !isDue(target.container, now: now) {
                continue
            }
            // The other worktrees on their own, slower pace, whatever woke
            // the tick (`Target.isOccasional`).
            if target.isOccasional,
               let last = lastFetchAt[target.container],
               now.timeIntervalSince(last) < Self.occasionalInterval
            {
                continue
            }
            // One CLI at a time per tick: the lookup is awaited unless one
            // for the row was already running, which then runs once more
            // instead.
            await requestLookup(target.container, invalidatesForges: false)
            // Re-check after the await: a canceled task ends the tick
            // rather than going on to the next row.
            guard !Task.isCancelled else { return }
            attempted += 1
        }
        forgetGoneRows()
        let total = targets.count
        log.debug("""
        PR sync (\(reason.rawValue, privacy: .public)): \
        \(attempted, privacy: .public) of \(total, privacy: .public)
        """)
    }

    /// Drop what is kept for rows we no longer fetch for, at the end of
    /// every tick. Internal so the tests can run it without a whole tick.
    func forgetGoneRows() {
        guard let session else { return }
        // Rows come and go. Recomputed rather than reusing a tick's
        // snapshot because the tick awaited a CLI per row, and a worktree
        // added in that window would otherwise be pruned the moment it
        // appeared.
        let live = Set(Self.enumerableTargets(session: session).map(\.container))
        lastFetchAt = lastFetchAt.filter { live.contains($0.key) }
        lookupTokens = lookupTokens.filter { live.contains($0.key) }
        answeredHeads = answeredHeads.filter { live.contains($0.key) }
        leftBranches = leftBranches.filter { live.contains($0.key) }
        store?.prune(keeping: live)
    }

    /// One entry per sidebar row we are willing to fetch for.
    struct Target {
        let container: ContainerID
        let workingDirectory: URL
        /// One of the other worktrees, folded away: a worktree Git
        /// only reported, with no tab in it. Read at most every
        /// `occasionalInterval`, here and by `GitFactsStore`: a repository
        /// whose agents left fifty of them would otherwise run Git and the
        /// forge's CLI fifty times a cycle for rows nobody looks at. Opening
        /// one admits it, and it is read on the next cycle as any row is.
        var isOccasional = false
    }

    /// The least time between two reads of one of the other worktrees.
    static let occasionalInterval: TimeInterval = 300

    /// Snapshot the rows we fetch for, taken under MainActor.
    ///
    /// Includes each project's own root: `GitSyncCoordinator` keeps
    /// the main checkout out of `project.worktrees` because the
    /// Project row already stands for it, but that checkout has a
    /// branch and can have a request like any other. Leaving it out
    /// would mean the row a single-checkout user works in every day is
    /// the one row that never shows anything.
    ///
    /// Worktree rows drop out when they are missing on disk (nothing
    /// to run in), hidden (the sidebar isn't drawing them), or
    /// user-pinned — those are plain subdirectories with no branch of
    /// their own.
    ///
    /// Static and internal so tests can pin that row set without
    /// standing up a syncer and its six collaborators — same reason
    /// `ForgeResolver.classify` is reachable.
    static func enumerableTargets(session: WorkspaceSession) -> [Target] {
        session.projects.flatMap { project -> [Target] in
            let main = Target(
                container: .project(project.id),
                workingDirectory: project.rootURL
            )
            let worktrees = project.worktrees
                .filter(isFetchable)
                .map { worktree in
                    let container = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
                    return Target(
                        container: container,
                        workingDirectory: worktree.workingDirectory,
                        isOccasional: SidebarSectionRule.isUnopened(
                            admission: worktree.admission,
                            hasTabs: !session.tabs(in: container).isEmpty
                        )
                    )
                }
            return [main] + worktrees
        }
    }

    /// Whether a worktree row is one `enumerableTargets` fetches for.
    private static func isFetchable(_ worktree: Worktree) -> Bool {
        !worktree.isMissing && !worktree.isHidden && worktree.origin == .gitWorktree
    }

    /// Where `container` is fetched, while it is a row `enumerableTargets`
    /// fetches for; `nil` once it is not. Looked up directly rather than
    /// by scanning every row, since every lookup asks it twice.
    static func workingDirectory(of container: ContainerID, in session: WorkspaceSession) -> URL? {
        switch container {
        case .loose:
            nil
        case let .project(projectID):
            session.project(projectID)?.rootURL
        case let .worktree(projectID, worktreeID):
            session.worktree(projectID: projectID, worktreeID: worktreeID)
                .flatMap { isFetchable($0) ? $0.workingDirectory : nil }
        }
    }

    /// The branch the row for `container` shows, which an answer has to
    /// have been asked for to be kept (`CheckoutHead.admits`).
    static func head(of container: ContainerID, in session: WorkspaceSession) -> CheckoutHead {
        let branch: String?
        let commit: String?
        switch container {
        case .loose:
            return .unknown
        case let .project(projectID):
            let project = session.project(projectID)
            branch = project.flatMap { CheckoutName.of($0) }
            commit = project?.mainHeadSHA
        case let .worktree(projectID, worktreeID):
            let worktree = session.worktree(projectID: projectID, worktreeID: worktreeID)
            branch = worktree.flatMap { CheckoutName.branch(of: $0) }
            commit = worktree?.gitRef?.headSHA
        }
        if let branch {
            return .branch(branch)
        }
        // A commit with no branch is a detached HEAD; neither is a row Git
        // has not been read for yet.
        return commit.map { $0.isEmpty ? .unknown : .detached } ?? .unknown
    }

    // MARK: - Manual refresh

    /// Refetch one container immediately, ignoring the per-container
    /// floor. That floor exists to absorb *incidental* triggers; a user
    /// picking "Refresh" from the context menu has asked for exactly
    /// one fetch, and silently doing nothing because they refreshed 40
    /// seconds ago would read as the command being broken.
    func refreshNow(container: ContainerID) {
        Task { [weak self] in
            await self?.refresh(container: container)
        }
    }

    /// `refreshNow`, returning once its lookup has answered, or at once
    /// when it joined one already running as that lookup's follow-up.
    func refresh(container: ContainerID) async {
        // A manual refresh is also the moment to re-read remotes: the user
        // may have just added one, or authenticated a CLI, and this is the
        // only affordance that says "look again" out loud.
        await requestLookup(container, invalidatesForges: true)
    }

    /// An agent's turn ended in `container`: looked up at once, as a turn is
    /// often what opened or merged the request. Turns come at a person's pace,
    /// and the floor would miss a merge right after an earlier lookup. The
    /// forge is not re-read, as nothing says it changed.
    func turnEnded(in container: ContainerID) {
        Task { [weak self] in
            await self?.requestLookup(container, invalidatesForges: false)
        }
    }

    // MARK: - Lookup

    /// Look `container`'s request up, or, while a lookup for it is running,
    /// ask that one to run once more when it ends. Requests made while it
    /// runs come to one more lookup, however many there were.
    ///
    /// Returns once the lookups this call ran have answered, follow-ups
    /// included. Each one starts only while the container is still a row
    /// we fetch for, so a row that went away stops launching the CLI.
    private func requestLookup(_ container: ContainerID, invalidatesForges: Bool) async {
        // The menu entry shows for a fixture's requests too, and refetches
        // nothing for them: a fixture never reaches a CLI.
        guard let fetcher else { return }
        if inFlight[container] != nil {
            inFlight[container]?.isRequested = true
            if invalidatesForges {
                inFlight[container]?.invalidatesForges = true
            }
            return
        }
        inFlight[container] = FollowUp()
        defer { inFlight[container] = nil }
        var isInvalidating = invalidatesForges
        while let session, let directory = Self.workingDirectory(of: container, in: session) {
            nextLookupToken &+= 1
            let token = nextLookupToken
            lookupTokens[container] = token
            lastFetchAt[container] = Date()
            if isInvalidating {
                await fetcher.invalidate()
            }
            let lookup = await fetcher.lookup(workingDirectory: directory)
            // A canceled task gives no answer and starts nothing more of its
            // own. A follow-up someone else asked for still runs, on a task
            // of its own: the caller that asked has already returned.
            guard !Task.isCancelled else {
                if let followUp = inFlight[container], followUp.isRequested {
                    Task { [weak self] in
                        await self?.requestLookup(container, invalidatesForges: followUp.invalidatesForges)
                    }
                }
                return
            }
            publish(lookup, for: container, token: token)
            guard let followUp = inFlight[container], followUp.isRequested else { return }
            isInvalidating = followUp.invalidatesForges
            inFlight[container] = FollowUp()
        }
    }

    /// Write `lookup` into the store if it still describes the row: its
    /// lookup is the container's latest, the row is still one we fetch for,
    /// and the row's checkout is on the branch the lookup asked about.
    private func publish(_ lookup: PRStatusFetcher.Lookup, for container: ContainerID, token: UInt64) {
        // No answer keeps what was known (`PRStatusFetcher.Lookup`).
        guard lookup.isAnswered, let session, let store else { return }
        guard lookupTokens[container] == token,
              Self.workingDirectory(of: container, in: session) != nil
        else {
            log.debug("PR lookup answered for a row that is gone; dropped")
            return
        }
        let rowHead = Self.head(of: container, in: session)
        guard rowHead.admits(lookup.head) else {
            log.debug("PR lookup answered for a branch the row does not show; cleared")
            // The checkout and the row disagree on the branch, so whatever
            // the row shows may be the other branch's request. Showing none
            // until an answer agrees offers less, never a second "Create PR"
            // or a "Clean Up Worktree…" for a request of another branch.
            forget(container, in: store)
            leftBranches[container] = rowHead
            return
        }
        store.update(container: container, info: lookup.info, forge: lookup.forge)
        answeredHeads[container] = lookup.head
        leftBranches[container] = nil
    }

    private func forget(_ container: ContainerID, in store: PRStatusStore) {
        answeredHeads[container] = nil
        store.update(container: container, info: nil, forge: nil)
    }

    /// Clear each row whose shown request was answered for a branch the
    /// row no longer shows, and look those rows up again, with the rows a
    /// branch mismatch left waiting (`leftBranches`) whose branch has moved
    /// since.
    ///
    /// A checkout switched to another branch keeps its row and so its
    /// stored request, and its next lookup can be minutes away; until
    /// then the row would show the previous branch's request, number, and
    /// CI. Checked on every wake, since it compares maps and runs the CLI
    /// only for the rows whose branch moved, once per move.
    func recheckLeftBranches() async {
        guard let session, let store, fetcher != nil else { return }
        var due: [ContainerID] = []
        for (container, answered) in answeredHeads where !Self.head(of: container, in: session).admits(answered) {
            forget(container, in: store)
            due.append(container)
        }
        for (container, shown) in leftBranches where Self.head(of: container, in: session) != shown {
            leftBranches[container] = nil
            due.append(container)
        }
        for container in due {
            await requestLookup(container, invalidatesForges: false)
            guard !Task.isCancelled else { return }
        }
    }

    /// Whether a recurring wake looks `container` up. A lookup a turn's end or
    /// the app's focus started can fall just short of a wake, so half a wake is
    /// forgiven: without it, the row would wait a whole wake more for a few
    /// seconds' difference.
    private func isDue(_ container: ContainerID, now: Date) -> Bool {
        Self.isDue(info: store?.info(for: container), lastFetch: lastFetchAt[container], now: now)
    }

    static func isDue(info: PRInfo?, lastFetch: Date?, now: Date) -> Bool {
        guard let interval = recurringInterval(for: info) else { return false }
        guard let lastFetch else { return true }
        return now.timeIntervalSince(lastFetch) >= interval - pollInterval / 2
    }

    private func shouldFetch(container: ContainerID, now: Date) -> Bool {
        guard let last = lastFetchAt[container] else { return true }
        return now.timeIntervalSince(last) >= perContainerMinInterval
    }

}
