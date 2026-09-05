// PRStatusSyncer.swift
// Limpid — schedules forge CLI lookups per container and writes the
// results into `PRStatusStore`. Sibling to `GitSyncCoordinator` but
// kept deliberately separate because:
//   - `gh` / `glab` are optional dependencies; a failure here must
//     never poison local `git` sync.
//   - Pull-request state moves on the forge's clock, not the local
//     repo's, so the cadence is time-driven rather than
//     mutation-driven.
//   - The feature is opt-in via Settings. Disabled means no timer and
//     no CLI calls, independent of the always-on git sync.
//
// Lifecycle:
//   - `init` takes every collaborator rather than reaching for the
//     session or the store through a global.
//   - `start()` arms a focus observer and a settings observer, and —
//     only while the feature is on — a recurring task. The observers
//     stay armed either way, because noticing the switch being turned
//     on is their job; every path they lead to consults the live
//     setting before issuing a CLI call.
//   - Turning the feature off clears the store rather than leaving
//     stale entries behind. The sidebar would hide them either way,
//     but a cleared store means re-enabling cannot flash a stale
//     entry before the first fetch lands.

import AppKit
import Foundation
import OSLog

private let log = Logger.limpid("git.pr.sync")

@MainActor
final class PRStatusSyncer {
    private weak var session: WindowSession?
    private weak var store: PRStatusStore?
    private weak var settings: SettingsStore?
    private weak var hoverPresentation: PRHoverPresentation?

    /// Owned rather than reached for globally, per the dependency
    /// policy stated on `AppState`.
    private let fetcher: PRStatusFetcher
    private let resolver: ForgeResolver

    /// Cadence while nothing is in flight. Long on purpose: a merged
    /// or approved request does not change on a schedule the user
    /// cares about, and every tick costs one CLI spawn per row.
    /// Coming back to the app refetches anyway (see `observeFocus`),
    /// so this is a backstop for a window left in the foreground.
    private let idleInterval: Duration = .seconds(PRStatusSyncer.refreshIntervalMinutes * 60)

    /// Cadence while any tracked request still has checks running.
    /// The idle cadence above is useless for watching CI: a run that
    /// finishes in a couple of minutes would still be reported as
    /// "running" well after it stopped. Polling faster only while
    /// something is actually pending gives the fast feedback without
    /// paying for it the rest of the time, and needs no setting for
    /// the user to reason about.
    ///
    /// Shorter than `perContainerMinInterval`, which is why that floor
    /// is not applied to the recurring tick — see `tick`.
    private let activeInterval: Duration = PRStatusSyncer.pollGranularity

    /// Single source of truth for the idle cadence. The Settings
    /// footer quotes this rather than repeating the number, so
    /// changing the interval can't leave the UI describing the old one.
    static let refreshIntervalMinutes = 5

    /// Whichever cadence the current state calls for.
    private var currentInterval: Duration {
        let hasRunningChecks = store?.perContainer.values
            .contains { $0.checks?.conclusion == .pending } ?? false
        return hasRunningChecks ? activeInterval : idleInterval
    }

    /// Per-container floor between focus-driven fetches, so rapid app
    /// switching cannot issue one CLI call per row per switch.
    /// `refreshNow` deliberately ignores it — see there.
    private let perContainerMinInterval: TimeInterval = 60

    /// Last attempted fetch time per container. We track attempts
    /// (not just successes) so the floor still applies when the CLI
    /// fails — otherwise an offline user with rapid focus churn would
    /// spawn a process per row per alt-tab.
    private var lastFetchAt: [ContainerID: Date] = [:]

    /// Last value of the Settings flag we acted on. See
    /// `observeSetting` for why the comparison is needed.
    private var lastKnownEnabled = false

    private var recurringTask: Task<Void, Never>?

    /// How often the recurring task wakes to reconsider. Equal to the
    /// active cadence, which is the shortest interval it ever has to
    /// honor — waking more often would decide nothing sooner.
    private static let pollGranularity: Duration = .seconds(45)

    /// AppKit observer token. Held with `nonisolated(unsafe)` so the
    /// nonisolated `deinit` can remove it; every mutation site
    /// (`observeFocus`) runs on @MainActor, so the unsafety is only
    /// paid at teardown — same posture as `GitSyncCoordinator`.
    private nonisolated(unsafe) var focusObserver: (any NSObjectProtocol)?

    init(
        session: WindowSession,
        store: PRStatusStore,
        settings: SettingsStore,
        hoverPresentation: PRHoverPresentation,
        resolver: ForgeResolver,
        locator: ToolLocator
    ) {
        self.session = session
        self.store = store
        self.settings = settings
        self.hoverPresentation = hoverPresentation
        self.resolver = resolver
        self.fetcher = PRStatusFetcher(resolver: resolver, locator: locator)
    }

    deinit {
        if let f = focusObserver {
            NotificationCenter.default.removeObserver(f)
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Demo mode takes `DemoFixture` as the whole truth and never
        // reaches a CLI. Letting the live path run would make the hero
        // screenshot depend on the contributor's checkouts and forge
        // credentials, which is the one thing that pipeline promises
        // it does not. `AgentStateTracker` stops at the same door for
        // the same reason.
        guard !DemoFixture.isDemoActive else {
            for (container, info) in DemoFixture.prStatus {
                store?.update(container: container, info: info)
            }
            return
        }
        lastKnownEnabled = isEnabled()
        observeFocus()
        observeSetting()
        // Only armed while the feature is on. The recurring task wakes
        // often enough (see `pollGranularity`) that leaving it running
        // for a switched-off feature would be a timer firing on the
        // main actor every 45s to decide it has nothing to do — for
        // every user who never turns this on, which is the default.
        guard isEnabled() else { return }
        scheduleRecurring()
        // start() runs on @MainActor, so the implicit Task isolation
        // is also @MainActor — no need to re-annotate.
        Task { [weak self] in
            await self?.tick(reason: .initial)
        }
    }

    // MARK: - Triggers

    /// React to the Settings toggle immediately. Settings is a
    /// separate window of the same app, so closing it raises no
    /// `didBecomeActive` — without this the user would flip the switch
    /// on and stare at an unchanged sidebar until the next scheduled
    /// tick.
    ///
    /// Observation tracks `SettingsStore.settings` as one value, so
    /// this fires for every preference the user touches, font size
    /// included. We diff against the last seen flag because the work
    /// below is not free: `invalidate()` throws away the host cache,
    /// and rebuilding it costs an auth probe per host — a network
    /// round trip on the GitLab path. Same reason
    /// `startSettingsConfigSync` keeps `lastAppliedSettings`.
    private func observeSetting() {
        observeRepeatedly { [weak self] in
            _ = self?.settings?.settings.advanced.showPRStatusInSidebar
        } onChange: { [weak self] in
            guard let self else { return }
            let current = isEnabled()
            guard current != lastKnownEnabled else { return }
            lastKnownEnabled = current
            if current {
                scheduleRecurring()
                // Remotes may have been added, or a CLI authenticated,
                // since we last looked. Re-reading is cheap next to
                // making the user restart.
                Task {
                    await resolver.invalidate()
                    await self.tick(reason: .settingChanged)
                }
            } else {
                // Drop everything so re-enabling starts from a clean
                // slate and no stale entry can flash before the first
                // fetch lands. The presentation reset also removes a
                // card that happens to be open at this moment — its
                // anchor row is about to stop explaining it.
                recurringTask?.cancel()
                recurringTask = nil
                store?.clear()
                hoverPresentation?.reset()
                lastFetchAt.removeAll()
            }
        }
    }

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

    /// Wake on a fixed granularity and tick once enough of it has
    /// accumulated, rather than sleeping for the whole interval.
    ///
    /// A single long sleep can't answer a cadence change that happens
    /// while it is under way: a focus tick that finds a run in flight
    /// wants the fast rhythm now, not when the idle sleep it already
    /// committed to expires. Cancelling and re-arming the task would
    /// shorten it, but cancellation reaches whatever `tick` that task
    /// is running, and a cancelled `runTool` reports the same nil as a
    /// CLI that found no request — so the tick would erase the very
    /// rows it was refreshing. Waking often and deciding cheaply has
    /// no such edge: nothing is interrupted, and a wake that does not
    /// tick costs one comparison.
    private func scheduleRecurring() {
        recurringTask?.cancel()
        recurringTask = Task { [weak self] in
            var waited: Duration = .zero
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollGranularity)
                // `self` is only reached after the sleep so the task
                // does not hold the syncer alive across it.
                guard !Task.isCancelled, let self else { return }
                waited += Self.pollGranularity
                // Re-read every wake: the cadence moves in both
                // directions as runs start and finish.
                guard waited >= currentInterval else { continue }
                waited = .zero
                await tick(reason: .recurring)
            }
        }
    }

    // MARK: - Tick

    private enum Reason: String {
        case initial
        case recurring
        case focus
        case settingChanged
    }

    private func tick(reason: Reason) async {
        guard isEnabled() else { return }
        guard let session else { return }
        let now = Date()
        let targets = Self.enumerableTargets(session: session)
        var attempted = 0
        for target in targets {
            // The floor is for the one trigger whose rate the user
            // sets: alt-tabbing back. The others pace themselves —
            // `.recurring` *is* the pace, `.initial` runs once, and
            // `.settingChanged` arrives having just cleared
            // `lastFetchAt` on its way through the disable path, so a
            // floor would see no stamps to compare against anyway.
            //
            // Flooring `.recurring` would also put the active cadence
            // out of reach: 45s rounds against a 60s floor refetch
            // every 90s, watching a CI run at half the rate this file
            // claims.
            if reason == .focus, !shouldFetch(container: target.container, now: now) {
                continue
            }
            lastFetchAt[target.container] = now
            let info = await fetcher.fetch(workingDirectory: target.workingDirectory)
            // Re-check after the await. Two ways this tick can have
            // been overtaken: the user switched the feature off, in
            // which case writing would resurrect state the disable path
            // just cleared; or this task was cancelled, in which case
            // `fetch` reports the same nil a CLI reports for "no
            // request" and writing it would erase a row that has one.
            guard isEnabled(), !Task.isCancelled, let store else { return }
            store.update(container: target.container, info: info)
            attempted += 1
        }
        // Rows come and go. Recomputed rather than reusing the snapshot
        // above because the loop awaited a CLI per row, and a worktree
        // added in that window would otherwise be pruned the moment it
        // appeared.
        let live = Set(Self.enumerableTargets(session: session).map(\.container))
        lastFetchAt = lastFetchAt.filter { live.contains($0.key) }
        store?.prune(keeping: live)
        let total = targets.count
        log.debug("""
        PR sync (\(reason.rawValue, privacy: .public)): \
        \(attempted, privacy: .public) of \(total, privacy: .public)
        """)
    }

    /// One entry per sidebar row we are willing to fetch for.
    struct Target {
        let container: ContainerID
        let workingDirectory: URL
    }

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
    static func enumerableTargets(session: WindowSession) -> [Target] {
        session.projects.flatMap { project -> [Target] in
            let main = Target(
                container: .project(project.id),
                workingDirectory: project.rootURL
            )
            let worktrees = project.worktrees
                .filter { !$0.isMissing && !$0.isHidden && $0.origin == .gitWorktree }
                .map {
                    Target(
                        container: .worktree(projectID: project.id, worktreeID: $0.id),
                        workingDirectory: $0.workingDirectory
                    )
                }
            return [main] + worktrees
        }
    }

    // MARK: - Manual refresh

    /// Refetch one container immediately, ignoring the per-container
    /// floor. That floor exists to absorb *incidental* triggers; a user
    /// picking "Refresh" from the context menu has asked for exactly
    /// one fetch, and silently doing nothing because they refreshed 40
    /// seconds ago would read as the command being broken.
    func refreshNow(container: ContainerID) {
        // Same door as `start()`: the menu entry exists in demo mode
        // because the feature is switched on there, but it must not
        // reach a CLI either.
        guard !DemoFixture.isDemoActive else { return }
        guard isEnabled(), let session, let store else { return }
        let match = Self.enumerableTargets(session: session)
            .first { $0.container == container }
        guard let target = match else { return }
        let fetcher = fetcher
        let resolver = resolver
        Task { [weak self] in
            // A manual refresh is also the moment to re-read remotes:
            // the user may have just added one, or authenticated a
            // CLI, and this is the only affordance that says "look
            // again" out loud.
            await resolver.invalidate()
            let info = await fetcher.fetch(workingDirectory: target.workingDirectory)
            guard let self, isEnabled() else { return }
            lastFetchAt[container] = Date()
            store.update(container: container, info: info)
        }
    }

    private func shouldFetch(container: ContainerID, now: Date) -> Bool {
        guard let last = lastFetchAt[container] else { return true }
        return now.timeIntervalSince(last) >= perContainerMinInterval
    }

    // MARK: - Settings

    private func isEnabled() -> Bool {
        settings?.settings.advanced.showPRStatusInSidebar ?? false
    }
}
