// AttentionState.swift
// Limpid — cross-pane attention state ("the ring"): drives the
// container column's Waiting list, the ⌘J cursor, and the
// finished-turn viewed → acknowledged indicator → dismissed lifecycle.
// Every fact comes from the Rust-backed runtime projection: runtimes are
// the only source of waiting rows, and the viewed / dismissed marks are
// keyed by runtime id plus the runtime's episode token
// (`attentionEventToken`). Held
// alongside `WindowSession` (not inside it) so the raw agent-lifecycle
// facts stay separate from the UI's "what's still asking for the user"
// view. Wired via `@Environment(AttentionState.self)` from `AppState`.

import Foundation

/// The dominant lifecycle state for a scope plus the acknowledgement
/// state that only a finished indicator can carry.
struct AgentStateSummary: Equatable {
    let state: AgentState
    let isViewedFinished: Bool
}

/// What a container row shows for the agents inside it: the one badge that
/// stands for all of them, and how many are in each state.
struct AgentStateReport: Equatable {
    let summary: AgentStateSummary?
    let breakdown: [AgentState: Int]
}

@MainActor
@Observable
final class AttentionState {
    /// Runtime facts are transient; native session snapshots stay compatible.
    var runtimesByKind: [AgentKind: [AgentRuntimePresentation]] = [:]
    var viewedRuntimeTokens: [String: String] = [:]
    var dismissedRuntimeTokens: [String: String] = [:]
    var onRuntimeAttentionChanged: (() -> Void)?
    /// Lets the notification history acknowledge non-agent output when
    /// focus moves between panes without changing the active tab.
    var onPaneFocused: ((UUID) -> Void)?
    /// Injected by `AppState` so Core can keep attention navigation unified
    /// without owning Settings or the window's Review presentation.
    var isTurnReviewEnabled: () -> Bool = { false }
    var onFinishedTurnFocused: ((UUID, String, String) -> Void)?
    var selectedRuntimeID: String?

    /// Container column Waiting list filter — when false, viewed-finished rows are
    /// hidden so the list shows only "next to deal with". `needsInput` /
    /// `error` are never hidden (they always demand a response). Session-
    /// scoped (not persisted) so the user starts each launch with the
    /// fuller picture.
    var includeViewed: Bool = true

    /// How long a *viewed* finished turn stays listed before it is
    /// treated as dismissed. Viewing keeps a row available in the All
    /// filter, so without a ceiling a turn the user glanced at days ago
    /// keeps a slot in Waiting until they press ×. A day is long enough to still find yesterday's
    /// result, short enough that a Monday sidebar doesn't open on
    /// Friday's leftovers. `needsInput` / `error` never age out.
    static let viewedFinishedRetention: TimeInterval = 24 * 60 * 60

    /// Clock for the retention rule. Injected so tests can move time
    /// instead of waiting a day.
    var now: () -> Date = { Date() }

    /// Whether a viewed finished turn stamped at `updatedAt` has aged
    /// past `viewedFinishedRetention`.
    func isPastRetention(_ updatedAt: Date) -> Bool {
        now().timeIntervalSince(updatedAt) > Self.viewedFinishedRetention
    }

    // MARK: - Mutation

    /// Mark every finished runtime visible in a pane as viewed — focus
    /// has visited it. The row switches to its acknowledged style but
    /// stays. Cleared automatically when the next episode starts.
    func markViewed(paneID: UUID) {
        markVisibleRuntimesViewed(paneID: paneID)
    }

    /// Called by every focus-change site (mount, click, ⌘J, tab switch,
    /// arrow). Marks the *arrived* pane's finished turn as viewed.
    func focusMoved(to newPane: UUID?, in session: WindowSession) {
        if let newPane {
            markViewed(paneID: newPane)
            onPaneFocused?(newPane)
        }
    }
}

// MARK: - Aggregate AgentState (dismissed-filtered)

@MainActor
extension AttentionState {
    /// One pane's contribution to an container / tab column aggregate — the raw agent
    /// state plus whether a `.finished` turn has already been viewed.
    /// The viewed flag is what lets the aggregator demote a "check
    /// already glanced at" below a sibling that's still running, so
    /// `{running, viewed-finished}` shows `running` instead of the
    /// stale finished check.
    private struct PaneAgentState {
        let id: String
        let state: AgentState
        /// Only meaningful for `.finished` — every other state ignores it.
        let isViewed: Bool
    }

    /// Every observed agent state for a tab's panes (Claude + Codex
    /// merged), with any dismissed-finished turns filtered out so a
    /// finished pane the user has dismissed stops contributing to the
    /// container / tab column aggregate badge — same "dismissed → gone" rule the
    /// Waiting list uses. Live-agent / close-confirmation predicates
    /// on `WindowSession` read raw badges and are intentionally NOT
    /// filtered through here (a dismissed-finished pane is still a live
    /// session worth confirming before close).
    private func allAgentStates(in tab: Tab) -> [PaneAgentState] {
        let leaves = Set(tab.splitTree.allLeafIDs())
        return allRuntimes.filter {
            !$0.paneIDs.isDisjoint(with: leaves) && !($0.badge.state == .finished && isDismissed($0))
        }.map { PaneAgentState(id: $0.id, state: $0.badge.state, isViewed: isViewed($0)) }
    }

    private func scopeAgentStates(across tabs: [Tab]) -> [PaneAgentState] {
        var unique: [String: PaneAgentState] = [:]
        for tab in tabs {
            for state in allAgentStates(in: tab) {
                unique[state.id] = state
            }
        }
        return unique.values.sorted { $0.id < $1.id }
    }

    /// Two-stage reducer: viewed-finished contributions are kept only
    /// as a fallback. If any other state is present (including
    /// `running` / `compacting`), that wins so a sibling pane still
    /// doing work outranks a check the user has already glanced at.
    /// Without this, `.finished` (priority 3) silently dominates
    /// `.running` (priority 2) even when the finished badge is
    /// already shown as an acknowledged outline.
    private static func aggregateDemotingViewed(_ states: [PaneAgentState]) -> AgentStateSummary? {
        let nonViewedFinished = states
            .filter { !($0.state == .finished && $0.isViewed) }
            .map(\.state)
        if let primary = nonViewedFinished.aggregateAgentState() {
            return AgentStateSummary(state: primary, isViewedFinished: false)
        }
        return states.contains(where: { $0.state == .finished && $0.isViewed })
            ? AgentStateSummary(state: .finished, isViewedFinished: true)
            : nil
    }

    /// Aggregate summary for a single tab, retaining whether its displayed
    /// finished result has already been viewed.
    func aggregateAgentStateSummary(in tab: Tab) -> AgentStateSummary? {
        Self.aggregateDemotingViewed(allAgentStates(in: tab))
    }

    /// Summary and per-state counts across every tab in the given container.
    ///
    /// One walk of the runtimes for both, because a container row shows
    /// both. Asking for them through two calls walked the same tabs twice
    /// for every row on every render.
    func agentStateReport(in container: ContainerID, session: WindowSession) -> AgentStateReport {
        Self.report(scopeAgentStates(across: session.tabs(in: container)))
    }

    /// The same across project-direct + every worktree inside the project.
    func agentStateReportInProject(_ projectID: UUID, session: WindowSession) -> AgentStateReport {
        Self.report(scopeAgentStates(across: session.tabs.filter { $0.container.projectID == projectID }))
    }

    /// Counts invocations, not copies of them on multiple client surfaces:
    /// `scopeAgentStates` has already folded a tmux run shown in several
    /// panes into one entry.
    private static func report(_ states: [PaneAgentState]) -> AgentStateReport {
        var breakdown: [AgentState: Int] = [:]
        for entry in states {
            breakdown[entry.state, default: 0] += 1
        }
        return AgentStateReport(summary: aggregateDemotingViewed(states), breakdown: breakdown)
    }
}

// MARK: - Attention list + cursor

@MainActor
extension AttentionState {
    /// Public, `Identifiable` view of one waiting target so the container column
    /// Waiting list can render it in the same order the ⌘J cursor
    /// walks. `id` is the runtime id — one entry per agent invocation, so
    /// a pane running two agents lists both.
    struct AttentionEntry: Identifiable {
        let tabID: UUID
        let paneID: UUID
        let state: AgentState
        /// When the badge was last written — shown as the row timestamp.
        let updatedAt: Date
        /// The turn's prompt, for the row's preview line. May be nil.
        let lastPrompt: String?
        /// State-specific text: the AskUserQuestion question / permission
        /// message (needsInput) or error type. Preferred over
        /// `lastPrompt` for the preview line when present.
        let detail: String?
        let turnBaseTree: String?
        let turnRoot: String?
        /// Focus has visited this finished turn — render its acknowledged
        /// indicator. Always false for needsInput / error.
        let isViewed: Bool
        var runtimeID: String
        var id: String {
            runtimeID
        }
    }

    /// One pane blocked on the user, plus its agent state (whose
    /// `.priority` drives the ordering).
    private struct AttentionTarget {
        let tabID: UUID
        let paneID: UUID
        let state: AgentState
        let updatedAt: Date
        let lastPrompt: String?
        let detail: String?
        let turnBaseTree: String?
        let turnRoot: String?
        /// Pre-computed so the sort comparator can stay self-contained.
        let isViewed: Bool
        var runtimeID: String
    }

    /// Every pane (across all tabs) whose agent is waiting on the user
    /// (`needsInput` / `error` / `finished`), ordered by **severity →
    /// unviewed first → age**:
    ///
    /// 1. `error` > `needsInput` > `finished` (severity tier)
    /// 2. within a tier, **unviewed** (the actually-next-up) before
    ///    **viewed** (already glanced at) — so a `finished` pane the user
    ///    hasn't seen yet floats above an older `finished` pane they've
    ///    already looked at
    /// 3. within those, oldest first so peers accumulate FIFO
    ///
    /// Step 2 only affects `finished` (needsInput / error don't carry the
    /// viewed flag). Both the container column list and the ⌘J cursor follow this
    /// order, so "next to deal with" is always at the top.
    private func attentionTargets(in session: WindowSession) -> [AttentionTarget] {
        var targets: [AttentionTarget] = []
        for runtime in allRuntimes {
            let badge = runtime.badge
            guard badge.state == .needsInput || badge.state == .error || badge.state == .finished,
                  !(badge.state == .finished && isDismissed(runtime))
            else { continue }
            let focused = session.activeTab?.splitTree.focusedLeafID
            let panes = runtime.paneIDs.sorted { $0.uuidString < $1.uuidString }
            guard let paneID = focused.flatMap({ runtime.paneIDs.contains($0) ? $0 : nil }) ?? panes.first,
                  let tab = session.tab(containing: paneID)
            else { continue }
            targets.append(AttentionTarget(
                tabID: tab.id, paneID: paneID, state: badge.state, updatedAt: badge.updatedAt,
                lastPrompt: badge.lastPrompt, detail: badge.detail,
                turnBaseTree: badge.turnBaseTree, turnRoot: badge.turnRoot,
                isViewed: isViewed(runtime), runtimeID: runtime.id
            ))
        }
        return targets.sorted { a, b in
            if a.state.priority != b.state.priority {
                return a.state.priority > b.state.priority
            }
            if a.isViewed != b.isViewed {
                // Unviewed (false) sorts before viewed (true) — the
                // user's "next to deal with" stays at the top of the tier.
                return !a.isViewed
            }
            return a.updatedAt < b.updatedAt
        }
    }

    /// `attentionTargets` after the `includeViewed` filter — the single
    /// source of truth for the visible Waiting list and the ⌘J cursor,
    /// so the cursor never lands on a row the user can't see. With the
    /// filter on (default) this matches `attentionTargets`; with it off,
    /// viewed-finished rows drop out (needsInput / error are never
    /// filtered — they always demand a response).
    private func visibleAttentionTargets(in session: WindowSession) -> [AttentionTarget] {
        attentionTargets(in: session)
            .filter { includeViewed || !($0.state == .finished && $0.isViewed) }
    }

    /// Count of finished panes the `includeViewed` filter is currently
    /// hiding. Used by the container column Waiting region to render a small
    /// "N hidden" hint when the filter is on and the visible list is
    /// otherwise empty. Returns 0 when the filter is off.
    func hiddenViewedCount(in session: WindowSession) -> Int {
        guard !includeViewed else { return 0 }
        return attentionTargets(in: session)
            .count(where: { $0.state == .finished && $0.isViewed })
    }

    /// Ordered entries for the container column Waiting list — same order
    /// the ⌘J / ⌘⇧J cursor walks (severity first, then oldest-waiting
    /// within each tier). Empty when nothing is waiting.
    func attentionEntries(in session: WindowSession) -> [AttentionEntry] {
        visibleAttentionTargets(in: session).map {
            AttentionEntry(
                tabID: $0.tabID,
                paneID: $0.paneID,
                state: $0.state,
                updatedAt: $0.updatedAt,
                lastPrompt: $0.lastPrompt,
                detail: $0.detail,
                turnBaseTree: $0.turnBaseTree,
                turnRoot: $0.turnRoot,
                isViewed: $0.isViewed,
                runtimeID: $0.runtimeID
            )
        }
    }

    /// ⌘J / ⌘⇧J — move focus to the next (`forward`) or previous pane
    /// whose agent is waiting on the user (`needsInput` / `error` /
    /// `finished`), cycling across every tab in severity-then-age order
    /// (most urgent / longest-waiting first). Answer a pane, press ⌘J,
    /// land on the next one waiting on you. `running` / `idle` panes are
    /// skipped — we only stop where the user is the blocker, so this
    /// never degrades into a plain tab cycler. The cursor walks the same
    /// visible list the container column Waiting region renders, so toggling the
    /// `includeViewed` filter off scopes ⌘J to the still-visible rows
    /// instead of stopping on ones the user has chosen to hide.
    ///
    /// When the focused pane is itself a target we step to the adjacent
    /// entry (cyclic) so repeated presses sweep every waiting pane;
    /// otherwise we jump to the oldest (forward) or newest (backward).
    /// No-op when nothing needs attention.
    func jumpToAttention(
        in session: WindowSession,
        registry: any SurfaceViewProviding,
        forward: Bool
    ) {
        let ordered = visibleAttentionTargets(in: session)
        guard !ordered.isEmpty else { return }
        let currentTab = session.activeTabID
        let currentPane = session.activeTab?.splitTree.focusedLeafID
        let currentIndex = ordered.firstIndex {
            $0.tabID == currentTab && $0.paneID == currentPane
                && $0.runtimeID == selectedRuntimeID
        }
        let target: AttentionTarget
        if let index = currentIndex {
            let step = forward ? 1 : -1
            target = ordered[(index + step + ordered.count) % ordered.count]
        } else {
            target = forward ? ordered[0] : ordered[ordered.count - 1]
        }
        focusAttention(in: session, registry: registry, tabID: target.tabID, paneID: target.paneID, runtimeID: target.runtimeID)
    }

    /// Jump straight to a specific target — used by the container column
    /// Waiting list when the user clicks a row.
    func focusAttention(
        in session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID,
        runtimeID: String? = nil
    ) {
        let target = attentionTargets(in: session).first {
            $0.tabID == tabID && $0.paneID == paneID
                && $0.runtimeID == runtimeID
        }
        selectedRuntimeID = runtimeID
        PaneActions.activateAndFocus(session, registry: registry, tabID: tabID, paneID: paneID)
        if let runtimeID,
           let location = allRuntimes.first(where: { $0.id == runtimeID })?.tmuxLocations[paneID],
           let tmuxPath = TmuxClientProbe.locateTmux()
        {
            DispatchQueue.global(qos: .userInitiated).async {
                TmuxClientProbe.selectPane(tmuxPath: tmuxPath, location: location)
            }
        }
        if target?.state == .finished, isTurnReviewEnabled(),
           let tree = target?.turnBaseTree, let root = target?.turnRoot
        {
            onFinishedTurnFocused?(paneID, tree, root)
        }
    }
}
