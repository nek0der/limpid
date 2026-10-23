// AttentionState.swift
// Limpid — cross-pane attention state ("the ring"): the runtimes, and the
// finished-turn viewed lifecycle. A run
// is viewed as its turn records say, or by its episode's viewed mark when no
// turn record stands for it. Which items are listed, and in what order ⌘J
// walks them, belongs to the attention list (`AttentionQueueStore`). Every
// fact comes from the Rust-backed runtime projection, and the viewed marks
// are keyed by runtime id plus the runtime's episode token
// (`attentionEventToken`). Held alongside `WorkspaceSession` (not inside it)
// so the raw agent-lifecycle facts stay separate from the UI's "what's
// still asking for the user" view. Wired via
// `@Environment(AttentionState.self)` from `AppState`.

import Foundation

@MainActor
@Observable
final class AttentionState {
    /// Runtime facts are transient; native session snapshots stay compatible.
    var runtimesByKind: [AgentKind: [AgentRuntimePresentation]] = [:]
    /// The episode each finished run was viewed in, by runtime id: the read
    /// state of a run no turn record stands for (`isViewed`).
    var viewedRuntimeTokens: [String: String] = [:]
    var onRuntimeAttentionChanged: (() -> Void)?
    /// Lets the notification history acknowledge non-agent output when
    /// focus moves between panes without changing the active tab.
    var onPaneFocused: ((UUID) -> Void)?
    /// Whether a finished run is read as its turn records say: every turn
    /// it stands for read by sight or passed by the viewed line. `nil` when
    /// no turn record stands for the run, and its episode's viewed mark
    /// decides. Set by the app layer, which holds the records; badges and
    /// the notification history read runs through `isViewed`, so they agree
    /// with the attention list.
    var turnReadDecision: (AgentRuntimePresentation) -> Bool? = { _ in nil }
    /// Reads what `turnReadDecision` reads, so an observer outside a view
    /// that asks `isViewed` looks again when the records, the read marks,
    /// or the viewed lines change. A view asking `isViewed` already reads
    /// them through the decision.
    var observeTurnReadSources: () -> Void = {}
    /// The clock and the answers behind the prompt cache marks. Owned
    /// here because the windows ride the runtimes this class already holds,
    /// and every view that shows a mark already reads attention.
    let promptCache = PromptCacheMonitor()

    /// Walks the attention list (⌘J when `true`, ⇧⌘J when `false`). Set by
    /// the app layer: the list lives above Core, and Core's shortcut
    /// dispatch reaches it through here.
    var walkAttention: ((_ forward: Bool) -> Void)?
    /// Whether the attention list holds anything, for enabling ⌘J in the
    /// command palette. Set by the app layer.
    var hasAttentionItems: () -> Bool = { false }

    // MARK: - Mutation

    /// Mark every finished runtime visible in a pane as viewed — focus
    /// has visited it. Cleared automatically when the next episode starts.
    func markViewed(paneID: UUID) {
        markVisibleRuntimesViewed(paneID: paneID)
    }

    /// Called by every focus-change site (mount, click, ⌘J, tab switch,
    /// arrow). Records the *arrived* pane's finished agent episode as
    /// viewed, and hands the pane to `onPaneFocused`, which marks its
    /// notifications read.
    func focusMoved(to newPane: UUID?, in session: WorkspaceSession) {
        if let newPane {
            markViewed(paneID: newPane)
            onPaneFocused?(newPane)
        }
    }
}

// MARK: - Agents by place

@MainActor
extension AttentionState {
    /// The agent a pane header speaks for: a runtime attached to the pane
    /// whose state is known, the most recently updated when the pane shows
    /// several (a tmux session can carry more than one run). An unknown
    /// state does not count, matching the tab row's agent glyph, so a pane
    /// reads as a shell again once its agent is gone.
    func headerRuntime(inPane paneID: UUID) -> AgentRuntimePresentation? {
        allRuntimes
            .filter { $0.paneIDs.contains(paneID) && $0.badge.state != .unknown }
            .max { $0.badge.updatedAt < $1.badge.updatedAt }
    }

    /// Whether an agent is in a turn (`AgentState.isMidTurn`) in one of
    /// `panes`: what the new worktree sheet says of the project's folder,
    /// and what holds "Create PR" back. Every run attached to
    /// such a pane counts, not only the one its header names: a second
    /// tmux session attached there, or a run left behind a resume, is at
    /// work in that place too.
    func isAgentMidTurn(inPanes panes: Set<UUID>) -> Bool {
        Self.isAgentMidTurn(allRuntimes, inPanes: panes)
    }

    static func isAgentMidTurn(_ runtimes: [AgentRuntimePresentation], inPanes panes: Set<UUID>) -> Bool {
        runtimes.contains { $0.badge.state.isMidTurn && !$0.paneIDs.isDisjoint(with: panes) }
    }

    /// How many agents run a turn (compacting included) across the
    /// project's folder and every worktree in it, for the project menu.
    /// Runs are counted, not the panes that show them: a tmux run shown
    /// in several panes counts once.
    func runningAgentCount(inProject projectID: UUID, session: WorkspaceSession) -> Int {
        let leaves = Set(session.tabs.filter { $0.container.projectID == projectID }.flatMap { $0.splitTree.allLeafIDs() })
        return Set(allRuntimes.filter { runtime in
            (runtime.badge.state == .running || runtime.badge.state == .compacting)
                && !runtime.paneIDs.isDisjoint(with: leaves)
        }.map(\.id)).count
    }
}

// MARK: - Navigation

@MainActor
extension AttentionState {
    /// The pane a runtime is shown in: a pane focused in a window's tab
    /// when it runs there, otherwise its first pane that is in a tab. `nil`
    /// when no pane of it is in a tab. The attention list, the sidebar, and
    /// the notification routing all use it, so they cannot pick different
    /// panes.
    static func shownPane(of runtime: AgentRuntimePresentation, in session: WorkspaceSession) -> UUID? {
        let panes = runtime.paneIDs
            .filter { session.tab(containing: $0) != nil }
            .sorted { $0.uuidString < $1.uuidString }
        let focused = Set(session.shownTabIDs.compactMap { session.tab($0)?.splitTree.focusedLeafID })
        return panes.first(where: focused.contains) ?? panes.first
    }

    /// Brings an agent's pane into view: activates its tab, focuses it, and
    /// selects the agent's tmux pane. The attention list's navigator
    /// (`AppState.go(to:opensTurnReview:in:)`) reaches it through
    /// `ReviewTargetMove.toAgentPane` for ⌘J, the lists, a card's item, and
    /// notifications.
    ///
    /// The window and the intent stay two arguments, as in every selection:
    /// one value for both would hide the intent at the call site.
    func focusAttention( // swiftlint:disable:this function_parameter_count
        in session: WorkspaceSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID,
        runtimeID: String? = nil,
        window: WindowID,
        intent: SelectionIntent
    ) {
        PaneActions.activateAndFocus(session, registry: registry, tabID: tabID, paneID: paneID, in: window, intent: intent)
        if let runtimeID,
           let location = allRuntimes.first(where: { $0.id == runtimeID })?.tmuxLocations[paneID],
           let tmuxPath = TmuxClientProbe.locateTmux()
        {
            DispatchQueue.global(qos: .userInitiated).async {
                TmuxClientProbe.selectPane(tmuxPath: tmuxPath, location: location)
            }
        }
    }
}
