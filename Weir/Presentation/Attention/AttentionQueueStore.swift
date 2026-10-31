// AttentionQueueStore.swift
// Weir — the app's one attention list, rebuilt from runtimes, requests, and visibility.

import Foundation
import Observation

/// Holds the attention list every window reads, and builds the reducer's
/// input from what the app knows.
///
/// One for the whole app: a request or a stop is the same item whichever
/// window shows it. The list is not saved; it is rebuilt from the runtimes,
/// which the projection restores, and from the approval ledger.
@MainActor
@Observable
final class AttentionQueueStore {
    private(set) var queue = AttentionQueue()
    /// Carries out the effects of a change (the VoiceOver announcement).
    /// Set by the app layer, which owns VoiceOver.
    @ObservationIgnored var performEffects: ([AttentionEffect]) -> Void = { _ in }
    /// Takes the person to an item. Set by the app layer, which owns the
    /// panes, the windows, and the approval card. Weak because the app
    /// state that implements it owns this store.
    @ObservationIgnored weak var navigator: (any AttentionNavigating)?

    var hasItems: Bool {
        !queue.items.isEmpty
    }

    /// The item ⌘J would go to from `window`, without moving there, and the
    /// project ⌘J counts as the window's: the decision bar names it after
    /// an item is handled.
    func peekNext(from window: ProjectWindowState) -> (item: AttentionItem, windowProjectID: UUID?)? {
        let projectID = navigator?.projectID(of: window)
        let (_, id) = AttentionCursor.step(window.cursor, queue: queue, currentProjectID: projectID, forward: true)
        guard let item = queue.items.first(where: { $0.id == id }) else { return nil }
        return (item, projectID)
    }

    /// Going to an item gives the keyboard to its pane: a panel over the
    /// whole window it was asked from, and over the window it goes to (All
    /// Projects, the keyboard shortcuts panel), closes rather than lie over
    /// a terminal taking keys.
    private static func closeSheets(over windows: [ProjectWindowState]) {
        for window in windows {
            window.closeWindowOverlays()
        }
    }

    /// ⌘J (`forward`) or ⇧⌘J from `window`: moves its cursor and goes to
    /// the item it lands on.
    func jump(forward: Bool, in window: ProjectWindowState) {
        let projectID = navigator?.projectID(of: window)
        let (cursor, id) = AttentionCursor.step(window.cursor, queue: queue, currentProjectID: projectID, forward: forward)
        window.cursor = cursor
        guard let id, let item = queue.items.first(where: { $0.id == id }) else { return }
        let shown = navigator?.presentWindow(for: item, from: window) ?? window
        Self.closeSheets(over: [window, shown])
        show(item, onBarIn: shown)
        navigator?.go(to: item, opensTurnReview: true, in: shown)
        recordWindowProject(of: window)
        handOverCursor(from: window, to: shown)
    }

    /// ⌘J went on to another project's window: the walk goes on there,
    /// with the round as it stood, so the next ⌘J in front continues from
    /// the item rather than starting over.
    private func handOverCursor(from window: ProjectWindowState, to shown: ProjectWindowState) {
        guard shown !== window else { return }
        shown.cursor = window.cursor
        recordWindowProject(of: shown)
    }

    /// Goes to `item`, chosen from a list rather than by ⌘J. The window's
    /// cursor moves there too, so the next ⌘J continues from it. `window`
    /// is `nil` for a view outside any main window, which has no cursor.
    ///
    /// `opensInNewWindow`: the row was ⌘-clicked. An item of another
    /// project opens in a new window (`AttentionNavigating.presentNewWindow`),
    /// which the walk then goes on in, as after ⌘J went to another window.
    func focus(_ item: AttentionItem, from window: ProjectWindowState?, opensInNewWindow: Bool = false) {
        if let window {
            window.cursor = AttentionCursor.land(
                window.cursor,
                on: item,
                currentProjectID: navigator?.projectID(of: window)
            )
        }
        let presented = opensInNewWindow
            ? navigator?.presentNewWindow(for: item, from: window)
            : navigator?.presentWindow(for: item, from: window)
        let shown = presented ?? window
        Self.closeSheets(over: [window, shown].compactMap(\.self))
        if let shown {
            show(item, onBarIn: shown)
        }
        navigator?.go(to: item, opensTurnReview: false, in: shown)
        if let window {
            recordWindowProject(of: window)
            if let shown {
                handOverCursor(from: window, to: shown)
            }
        }
    }

    /// The pane's decision bar shows the item gone to, and any "Done"
    /// line the window was showing gives way: the person has moved on.
    /// `window` is the one that shows the pane, which need not be the one
    /// ⌘J or the list was used in.
    private func show(_ item: AttentionItem, onBarIn window: ProjectWindowState) {
        window.decisionBarDone = [:]
        if let paneID = item.subject.paneID {
            window.decisionBarSelection[paneID] = item.id
        }
    }

    /// Notes the project the window shows once the move is done: the item's
    /// own, or the same as before for a request that only opened its card.
    /// A different one at the next ⌘J is then the person's own doing.
    private func recordWindowProject(of window: ProjectWindowState) {
        window.cursor.windowGroup = AttentionCursorGroup(navigator?.projectID(of: window))
    }

    /// Goes to the pane of the runtime a notification came from: through
    /// its item when the list holds one (so ⌘J continues from there), else
    /// straight to the pane it runs in now. False when it runs nowhere.
    @discardableResult
    func focus(runtimeID: String, from window: ProjectWindowState?) -> Bool {
        let item = queue.items.first { item in
            guard case let .runtime(id, _, _, _, _) = item.subject else { return false }
            return id == runtimeID
        }
        if let item {
            focus(item, from: window)
            return true
        }
        return navigator?.go(toRuntime: runtimeID, in: window) ?? false
    }

    /// The item for a request, if the list holds it.
    func item(for key: ApprovalKey) -> AttentionItem? {
        queue.items.first { $0.id == .approval(key) || $0.id == .question(key) }
    }

    /// Applies one pass. `announces` is false until the runtimes have been
    /// matched to their panes once after launch: what was already waiting
    /// is listed then, and reading it all out would bury the one item that
    /// is new.
    func apply(_ input: AttentionQueueReducer.Input, announces: Bool) {
        let (next, effects) = AttentionQueueReducer.reduce(queue, input: input)
        if next != queue {
            queue = next
        }
        if announces, !effects.isEmpty {
            performEffects(effects)
        }
    }

    /// The reducer's input from the runtimes and the ledger.
    ///
    /// A runtime is shown in the focused pane when it runs there, otherwise in
    /// its first pane that is in a tab (`AttentionState.shownPane`, which the
    /// sidebar and the notification routing use too); one in no tab is left
    /// out. `isRead` is the read mark the app keeps for this launch: the pane
    /// was opened or seen as the turn ended, or the turn was read from a
    /// notification.
    static func makeInput(
        runtimes: [AgentRuntimePresentation],
        isRead: (AgentRuntimePresentation) -> Bool,
        unreadTurns: [String: [UnreadTurnEntry]] = [:],
        approvals: [AttentionQueueReducer.PlacedApproval],
        session: WorkspaceSession,
        isApprovalServiceRunning: Bool,
        launches: [SessionLaunch] = []
    ) -> AttentionQueueReducer.Input {
        let facts = runtimes.compactMap { runtime -> RuntimeFact? in
            guard let shown = AttentionState.shownPane(of: runtime, in: session) else { return nil }
            let tab = session.tab(containing: shown)
            let others = runtime.paneIDs
                .filter { $0 != shown && session.tab(containing: $0) != nil }
                .sorted { $0.uuidString < $1.uuidString }
            return RuntimeFact(
                runtimeID: runtime.id,
                provider: runtime.kind,
                paneIDs: [shown] + others,
                tabID: tab?.id,
                projectID: tab?.container.projectID,
                state: runtime.badge.state,
                updatedAt: runtime.badge.updatedAt,
                episodeToken: runtime.attentionEventToken,
                isEpisodeRead: isRead(runtime),
                detail: runtime.badge.detail,
                unreadTurns: unreadTurns[runtime.id],
                conversation: runtime.conversation,
                sessionID: runtime.sessionID,
                currentTurnID: runtime.currentTurnID,
                usageLimit: runtime.badge.usageLimit,
                waitKind: runtime.badge.promptWaitKind,
                tool: runtime.badge.tool,
                hasProcessExited: runtime.badge.hasProcessExited,
                hasPrompt: runtime.badge.hasPrompt
            )
        }
        // A hidden row is not shown, so its worktree's stop would be listed
        // where nothing names it.
        let missingWorktrees = session.projects.flatMap { project in
            project.worktrees.compactMap { worktree -> AttentionQueueReducer.MissingWorktree? in
                guard !worktree.isHidden, let since = worktree.missingSince else { return nil }
                return AttentionQueueReducer.MissingWorktree(
                    projectID: project.id,
                    worktreeRoot: worktree.workingDirectory,
                    missingSince: since
                )
            }
        }
        return AttentionQueueReducer.Input(
            runtimes: facts,
            approvals: approvals,
            isApprovalServiceRunning: isApprovalServiceRunning,
            launchFailures: launches.compactMap { launch in
                launch.failure.map { failure in
                    AttentionQueueReducer.LaunchFailure(
                        projectID: launch.projectID,
                        worktreeRoot: launch.worktreeRoot,
                        stage: failure.stage,
                        logTail: failure.logTail,
                        token: failure.token,
                        failedAt: failure.failedAt
                    )
                }
            },
            missingWorktrees: missingWorktrees
        )
    }

    /// The panes in sight now that were not at the last look. Opening a
    /// pane reads what finished there, as focusing one always has; a pane
    /// that stays in sight reads nothing new by staying.
    static func panesComingIntoSight(previous: Set<UUID>, current: Set<UUID>) -> Set<UUID> {
        current.subtracting(previous)
    }
}
