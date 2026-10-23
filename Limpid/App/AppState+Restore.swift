// AppState+Restore.swift
// Limpid — what the restore gate is asked about a turn's worktree, and the recovery of restores a quit cut short.

import Foundation

extension AppState {
    /// The turns restores took back and that are not undone, in every
    /// worktree (`RestoredTurns.ids`): the one answer the changes panel,
    /// the review, the attention list, and the restore strip all read.
    ///
    /// The answer is kept until the history, the journals, or the path
    /// spellings change (`RestoredTurnsMemo`): every projection pass, list
    /// rebuild, and draw asks for it, and each working out reads the whole
    /// history. An Undo and the journal sweep change the journals, so the
    /// answer is worked out again after them.
    func restoredTurnIDs() -> Set<TurnID> {
        let history = agentProjection.turnHistory
        let key = RestoredTurnsMemo.Key(
            historyRevision: history.revision,
            journals: restores.journals,
            pathGeneration: worktreePaths.generation
        )
        return RestoredTurnsMemo.ids(for: key, kept: &restoredTurnsMemo) { [worktreePaths] in
            RestoredTurns.ids(journals: $0.journals, history: history.conversations, isRoot: worktreePaths.isRoot)
        }
    }

    /// What the restore gate weighs for `turn`, from what the app
    /// knows now (`RestoreGate.input`). Read afresh on each call: this is
    /// what a restore or a discard asks right before it runs.
    func restoreGateInput(for turn: TurnSummary) -> RestoreGate.Input {
        restoreGateLookup().input(for: turn)
    }

    /// What the restore gate weighs, read from the app once, for a surface
    /// that asks about many turns at once (`RestoreGateLookup`).
    func restoreGateLookup() -> RestoreGateLookup {
        RestoreGateLookup(
            tabs: session.tabs.map { tab in
                RestoreGateLookup.Tab(
                    directory: ReviewAgents.directory(for: tab.container, in: session),
                    panes: tab.splitTree.allLeafIDs()
                )
            },
            runtimes: attention.allRuntimes.map {
                RestoreGate.Runtime(
                    provider: $0.kind,
                    state: $0.badge.state,
                    conversation: $0.conversation,
                    paneIDs: $0.paneIDs,
                    roots: [$0.badge.worktreeRoot, $0.badge.turnRoot].compactMap(\.self)
                )
            },
            waitingPanes: Set(attentionQueue.queue.items.compactMap { item -> UUID? in
                switch item.kind {
                case .approval, .question, .prompt: item.subject.paneID
                case .stop, .unread: nil
                }
            }),
            isBusy: { [restores] in restores.isBusy($0) }
        )
    }

    /// How long the launch toast shows: it comes while the windows come
    /// back, when the person is not looking yet.
    static let launchToastLifetime: Double = 15
    /// How long recovery waits before reading again a worktree whose
    /// restore it could not settle (a hook held the lock);
    /// `recoveryAttempts` is how many times it reads.
    static let recoveryRetry: Duration = .seconds(30)
    static let recoveryAttempts = 3

    /// The worktrees the projects hold: each project's folder and each of
    /// its worktrees on disk, hidden ones too.
    var projectRestoreRoots: [String] {
        var roots = Set<String>()
        for project in session.projects {
            roots.insert(project.rootURL.path)
            for worktree in project.worktrees where !worktree.isMissing {
                roots.insert(worktree.workingDirectory.path)
            }
        }
        return roots.sorted()
    }

    /// Where the turns in history began, which may be a folder no project
    /// holds (an agent that changed directory).
    var historyRestoreRoots: [String] {
        Set(agentProjection.turnHistory.conversations.values.joined().compactMap(\.beginTree?.root)).sorted()
    }

    /// Reads every worktree's restore journals at launch, settling the
    /// restores a quit or a crash cut short, and tells the person
    /// once of each found stopped partway, with Undo to take back what it
    /// wrote. The projects' worktrees are read at once; the folders only the
    /// turns name, once the first projection pass has reported them, which
    /// a failing pass would never do.
    func recoverRestores() {
        guard writesUserFiles else { return }
        let projectRoots = Self.launchRestoreRoots(projects: projectRestoreRoots, pending: restores.pendingStopRoots)
        recoverRestores(at: projectRoots)
        agentProjection.turnHistory.whenLoaded { [weak self] in
            guard let self else { return }
            recoverRestores(at: Self.laterRestoreRoots(history: historyRestoreRoots, readAtOnce: projectRoots))
        }
    }

    /// Ties the viewed-line moves each restore made to its journal: they
    /// are kept until a whole reading of the worktree says the restore can
    /// no longer be undone, and taken back when it says it was undone
    /// (`ViewedLineStore.settleRestoreMoves`).
    func connectRestoreMoves() {
        restores.onWholeReading = { [weak viewedLines, worktreePaths] root, journals in
            viewedLines?.settleRestoreMoves(readOf: worktreePaths.isRoot(root), listing: journals)
        }
    }

    /// The worktrees read at once at launch: the projects', and those whose
    /// launch notice still waits for its operation, which are read though
    /// no project holds them now, as nothing else would tell that notice.
    static func launchRestoreRoots(projects: [String], pending: [String]) -> [String] {
        Set(projects).union(pending).sorted()
    }

    /// The folders only the turns name, read once history has loaded: the
    /// ones read at once are left out, so no worktree is read twice.
    static func laterRestoreRoots(history: [String], readAtOnce: [String]) -> [String] {
        let read = Set(readAtOnce)
        return history.filter { !read.contains($0) }
    }

    private func recoverRestores(at roots: [String]) {
        guard !roots.isEmpty else { return }
        Task { [restores] in
            await restores.recoverAtLaunch(
                roots: roots,
                attempts: Self.recoveryAttempts,
                retry: Self.recoveryRetry
            ) { [weak self] report in
                self?.announce(report)
            }
        }
    }

    /// The launch toast for what recovery settled: the operations cut
    /// short (and discards that ended as the app quit, whose review is
    /// gone), with Undo for all of them, or, with none, the saves recovery
    /// moved aside. One toast at a time.
    private func announce(_ found: RestoreCoordinator.RecoveryReport) {
        launchRecovery = launchRecovery.adding(found)
        // Undone or settled since from elsewhere (a restore's record): not
        // offered again.
        launchRecovery.stops = launchRecovery.stops.filter { stop in
            restores.journal(stop.undoable.opID, in: stop.undoable.root)?.isUndoable ?? true
        }
        let report = launchRecovery
        let locale = settingsStore.appLocale
        let aside = RestoreText.keptAsideSentence(report.keptAside, locale: locale)
        guard let kind = RecoveryNews.kind(report.stops) else {
            if let aside {
                let news = ToastKind.keptAsideAtQuit.message.resolved(in: locale)
                showLaunchToast(ToastItem(message: .verbatim(RestoreText.toast(news, note: aside, locale: locale)), undo: nil))
            }
            return
        }
        let stopped = report.interrupted
        let undo: () -> Void = { [weak self] in
            // Acted on: a later reading tells only what it finds itself.
            self?.launchRecovery = RestoreCoordinator.RecoveryReport()
            self?.undoStopped(stopped)
        }
        // Saves recovery kept aside are said with the news, as nothing else
        // is left to say where they went.
        let toast = if let aside {
            ToastItem(message: .verbatim(RestoreText.toast(kind.message.resolved(in: locale), note: aside, locale: locale)), undo: undo)
        } else {
            ToastItem(kind, undo: undo)
        }
        showLaunchToast(toast)
    }

    /// Undo of each operation the launch toast offered. A discard whose
    /// undo could not run or fell short is offered again with the reason,
    /// as no review is left to offer it; a restore's record does that for
    /// a restore.
    private func undoStopped(_ stopped: [RestoreJournal]) {
        Task { [restores] in
            let locale = settingsStore.appLocale
            var again: [RestoreJournal] = []
            var notes: [String] = []
            for offered in stopped {
                // As it stands now: undone or settled from elsewhere since the
                // toast came up (a restore's record), it is not tried again.
                let journal = restores.journal(offered.opID, in: offered.root) ?? offered
                guard journal.isUndoable else { continue }
                // Another operation of the worktree runs: this one waits for
                // the next try rather than read as one whose end is unknown.
                guard !restores.isBusy(journal.root) else {
                    again.append(journal)
                    notes.append(RestoreText.blocker(.restoring, locale: locale))
                    continue
                }
                let outcome = await restores.undo(journal)
                guard let failure = RestoreCoordinator.UndoResult(outcome), journal.operation == .discard else {
                    // Whole, or a restore whose record says how it fell
                    // short: only where saves went is left to say.
                    if let news = RestoreText.keptAsideNews(outcome, besides: journal.stage.keptAside, locale: locale) {
                        notes.append(news)
                    }
                    continue
                }
                // Its text names the saves moved aside. Only a try that may
                // go otherwise next time is offered again.
                notes.append(ReviewHunkDiscardText.undoFailed(failure, locale: locale))
                if failure.mayChange {
                    again.append(journal)
                }
            }
            // What may still be undone stays offered: a later reading's
            // toast takes it in rather than replace it.
            launchRecovery = launchRecovery.adding(RestoreCoordinator.RecoveryReport(
                stops: again.map { RestoreCoordinator.RecoveredStop(settled: $0, undoable: $0) }
            ))
            guard !notes.isEmpty else { return }
            var said = Set<String>()
            let text = RestoreText.joined(notes.filter { said.insert($0).inserted }, locale: locale)
            // Its Undo is for everything still offered, a later reading's
            // too, as this toast takes the place of the one that offered it.
            let pending = launchRecovery.interrupted
            showLaunchToast(ToastItem(message: .verbatim(text), undo: pending.isEmpty ? nil : { [weak self] in
                self?.launchRecovery = RestoreCoordinator.RecoveryReport()
                self?.undoStopped(pending)
            }))
        }
    }

    private func showLaunchToast(_ toast: ToastItem) {
        var toast = toast
        toast.lifetimeSeconds = Self.launchToastLifetime
        toastCenter.showInFrontWindow(toast)
    }
}

/// What the restore gate weighs (`RestoreGate.Facts`), read from the app
/// once and shared by every turn asked about while it lives.
///
/// The changes panel asks for each row it builds. Read per turn, every row
/// would go over every tab and resolve the symlinks of each tab's folder,
/// each agent's roots, and the turn's own: about ten thousand resolutions for
/// two hundred turns and fifty tabs, rows out of sight included. Here each
/// path is resolved once and each worktree's facts are gathered once.
///
/// It holds what the app knew when it was made, so it lives for one build
/// of a surface. A restore or a discard asks the gate again right before it
/// runs, through a new one (`AppState.restoreGateInput(for:)`).
@MainActor
final class RestoreGateLookup {
    /// A tab as the gate reads it: the folder its container holds, and its
    /// panes.
    struct Tab {
        let directory: URL?
        let panes: [UUID]
    }

    private let tabs: [Tab]
    private let runtimes: [RestoreGate.Runtime]
    private let waitingPanes: Set<UUID>
    private let isBusy: (String) -> Bool
    /// Resolves a path's symlinks; a test counts the calls.
    private let resolve: (URL) -> URL
    private var resolved: [URL: URL] = [:]
    private var resolvedByPath: [String: URL] = [:]
    private var factsByRoot: [String: RestoreGate.Facts] = [:]

    init(
        tabs: [Tab],
        runtimes: [RestoreGate.Runtime],
        waitingPanes: Set<UUID>,
        isBusy: @escaping (String) -> Bool,
        resolve: @escaping (URL) -> URL = { $0.resolvingSymlinksInPath() }
    ) {
        self.tabs = tabs
        self.runtimes = runtimes
        self.waitingPanes = waitingPanes
        self.isBusy = isBusy
        self.resolve = resolve
    }

    /// What the gate weighs for `turn` (`RestoreGate.input`).
    func input(for turn: TurnSummary) -> RestoreGate.Input {
        guard let root = turn.beginTree?.root else {
            return RestoreGate.Input(turn: turn, agents: [], isWaiting: false, isRestoring: false)
        }
        let target = resolved(path: root)
        return RestoreGate.input(for: turn, facts: facts(forRoot: root, target: target)) {
            self.resolved(path: $0) == target
        }
    }

    private func facts(forRoot root: String, target: URL) -> RestoreGate.Facts {
        if let facts = factsByRoot[root] {
            return facts
        }
        let tabPanes = Set(tabs.filter { tab in
            tab.directory.map { resolved($0) == target } ?? false
        }.flatMap(\.panes))
        let facts = RestoreGate.Facts(
            runtimes: runtimes,
            worktreeTabPanes: tabPanes,
            waitingPanes: waitingPanes,
            isRestoring: isBusy(root)
        )
        factsByRoot[root] = facts
        return facts
    }

    private func resolved(path: String) -> URL {
        if let url = resolvedByPath[path] {
            return url
        }
        let url = resolved(URL(fileURLWithPath: path))
        resolvedByPath[path] = url
        return url
    }

    private func resolved(_ url: URL) -> URL {
        if let known = resolved[url] {
            return known
        }
        let known = resolve(url)
        resolved[url] = known
        return known
    }
}
