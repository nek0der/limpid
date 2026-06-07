// AttentionState.swift
// Limpid — cross-pane attention state ("the ring"): drives the
// container column's Waiting list, the ⌘J cursor, and the
// finished-turn viewed → fade → dismissed lifecycle. Owns
// `viewed` / `dismissed` plus the derivations and actions that read
// them. Held alongside `WindowSession` (not inside it) so the raw
// agent-lifecycle facts stay separate from the UI's "what's still
// asking for the user" view. Wired via
// `@Environment(AttentionState.self)` from `AppState`.

import Foundation

@MainActor
@Observable
final class AttentionState {
    /// Per-pane "I've dismissed this finished turn" — the user pressed
    /// the row's ×. Keyed to the badge's `updatedAt`; a newer finished
    /// turn (later stamp) resurfaces automatically. `needsInput` / `error`
    /// are never dismissed this way — those clear only when the
    /// underlying state actually resolves.
    private(set) var dismissedAt: [UUID: Date] = [:]

    /// Per-pane "focus has visited this finished turn" — the row fades
    /// but stays listed (viewing is not completing). Keyed to badge
    /// `updatedAt` for the same resurfacing semantics.
    private(set) var viewedAt: [UUID: Date] = [:]

    /// Container column Waiting list filter — when false, viewed-finished rows are
    /// hidden so the list shows only "next to deal with". `needsInput` /
    /// `error` are never hidden (they always demand a response). Session-
    /// scoped (not persisted) so the user starts each launch with the
    /// fuller picture.
    var includeViewed: Bool = true

    // MARK: - Mutation

    /// Manually dismiss a pane's *finished* turn ("conversation's done")
    /// so it drops off the Waiting list + clears the container / tab column check.
    /// No-op unless the pane is currently `.finished`.
    func dismiss(paneID: UUID, in session: WindowSession) {
        guard let stamp = currentFinishedStamp(paneID: paneID, in: session) else { return }
        dismissedAt[paneID] = stamp
    }

    /// Mark a pane's *finished* turn as viewed — focus has visited it.
    /// The row fades but stays. Cleared automatically when the next turn
    /// starts (badge `updatedAt` advances).
    func markViewed(paneID: UUID, in session: WindowSession) {
        guard let stamp = currentFinishedStamp(paneID: paneID, in: session) else { return }
        if viewedAt[paneID] != stamp {
            viewedAt[paneID] = stamp
        }
    }

    /// Called by every focus-change site (mount, click, ⌘J, tab switch,
    /// arrow). Marks the *arrived* pane's finished turn as viewed.
    func focusMoved(to newPane: UUID?, in session: WindowSession) {
        if let newPane {
            markViewed(paneID: newPane, in: session)
        }
    }

    /// Drop a pane's attention state (call when the pane closes) so the
    /// dictionaries don't grow without bound across long sessions.
    func forget(paneID: UUID) {
        dismissedAt[paneID] = nil
        viewedAt[paneID] = nil
    }

    // MARK: - Queries

    /// Whether a `.finished` pane has been dismissed for its current turn.
    func isDismissed(paneID: UUID, badgeUpdatedAt: Date) -> Bool {
        guard let stamp = dismissedAt[paneID] else { return false }
        return badgeUpdatedAt <= stamp
    }

    /// Whether a `.finished` pane has been viewed for its current turn.
    func isViewed(paneID: UUID, badgeUpdatedAt: Date) -> Bool {
        guard let stamp = viewedAt[paneID] else { return false }
        return badgeUpdatedAt <= stamp
    }

    // MARK: - Helpers

    /// The current `.finished` badge stamp for a pane (Claude or Codex),
    /// or nil if the pane isn't sitting on a finished turn right now.
    func currentFinishedStamp(paneID: UUID, in session: WindowSession) -> Date? {
        guard let tab = session.tab(containing: paneID) else { return nil }
        if let b = tab.claudeAgentBadges[paneID], b.state == .finished { return b.updatedAt }
        if let b = tab.codexAgentBadges[paneID], b.state == .finished { return b.updatedAt }
        return nil
    }

    /// True iff a finished turn has been dismissed for this exact badge
    /// stamp. The container / tab column aggregate skips these so a dismissed pane
    /// stops contributing to its container's badge.
    private func isFinishedAndDismissed(paneID: UUID, state: AgentState, updatedAt: Date) -> Bool {
        state == .finished && isDismissed(paneID: paneID, badgeUpdatedAt: updatedAt)
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
    /// stale gray check.
    private struct PaneAgentState {
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
        var states: [PaneAgentState] = []
        for paneID in tab.splitTree.allLeafIDs() {
            if let b = tab.claudeAgentBadges[paneID],
               !isFinishedAndDismissed(paneID: paneID, state: b.state, updatedAt: b.updatedAt)
            {
                let viewed = b.state == .finished
                    && isViewed(paneID: paneID, badgeUpdatedAt: b.updatedAt)
                states.append(PaneAgentState(state: b.state, isViewed: viewed))
            }
            if let b = tab.codexAgentBadges[paneID],
               !isFinishedAndDismissed(paneID: paneID, state: b.state, updatedAt: b.updatedAt)
            {
                let viewed = b.state == .finished
                    && isViewed(paneID: paneID, badgeUpdatedAt: b.updatedAt)
                states.append(PaneAgentState(state: b.state, isViewed: viewed))
            }
        }
        return states
    }

    /// Two-stage reducer: viewed-finished contributions are kept only
    /// as a fallback. If any other state is present (including
    /// `running` / `compacting`), that wins so a sibling pane still
    /// doing work outranks a check the user has already glanced at.
    /// Without this, `.finished` (priority 3) silently dominates
    /// `.running` (priority 2) even when the finished badge is
    /// already grayed out.
    private static func aggregateDemotingViewed(_ states: [PaneAgentState]) -> AgentState? {
        let nonViewedFinished = states
            .filter { !($0.state == .finished && $0.isViewed) }
            .map(\.state)
        if let primary = nonViewedFinished.aggregateAgentState() {
            return primary
        }
        return states.contains(where: { $0.state == .finished && $0.isViewed })
            ? .finished
            : nil
    }

    /// Aggregate state for a single tab — drives the tab column row badge.
    func aggregateAgentState(in tab: Tab) -> AgentState? {
        Self.aggregateDemotingViewed(allAgentStates(in: tab))
    }

    /// Aggregate across every tab in the given container — container column group /
    /// project / worktree row badge.
    func aggregateAgentState(in container: ContainerID, session: WindowSession) -> AgentState? {
        Self.aggregateDemotingViewed(session.tabs(in: container).flatMap { allAgentStates(in: $0) })
    }

    /// Aggregate across project-direct + every worktree inside the
    /// project. Used by Project headers in container column.
    func aggregateAgentStateInProject(_ projectID: UUID, session: WindowSession) -> AgentState? {
        Self.aggregateDemotingViewed(
            session.tabs
                .filter { $0.container.projectID == projectID }
                .flatMap { allAgentStates(in: $0) }
        )
    }

    /// Per-state pane counts for the container column hover tooltip
    /// (`"1 error · 2 needsInput · 1 finished · 3 idle"`). Both Claude
    /// and Codex panes contribute; dismissed finished panes drop out.
    func agentStateBreakdown(in container: ContainerID, session: WindowSession) -> [AgentState: Int] {
        var out: [AgentState: Int] = [:]
        for tab in session.tabs(in: container) {
            for entry in allAgentStates(in: tab) {
                out[entry.state, default: 0] += 1
            }
        }
        return out
    }

    /// Same as the container variant but keyed off `Project.id`.
    func agentStateBreakdownInProject(_ projectID: UUID, session: WindowSession) -> [AgentState: Int] {
        var out: [AgentState: Int] = [:]
        for tab in session.tabs where tab.container.projectID == projectID {
            for entry in allAgentStates(in: tab) {
                out[entry.state, default: 0] += 1
            }
        }
        return out
    }

    // MARK: - Aggregate viewed (drives gray vs green check)

    /// Whether a scope's `.finished` contribution is entirely *viewed* —
    /// drives the gray (vs green) container / tab column check. True only when there is
    /// at least one finished pane and every finished pane has been
    /// viewed; a single unseen finished turn keeps the check green.
    /// Dismissed finished panes are excluded from the aggregate, so they
    /// don't count here either.
    func isFinishedAggregateViewed(in tab: Tab) -> Bool {
        finishedAllViewed(across: [tab])
    }

    func isFinishedAggregateViewed(in container: ContainerID, session: WindowSession) -> Bool {
        finishedAllViewed(across: session.tabs(in: container))
    }

    func isFinishedAggregateViewedInProject(_ projectID: UUID, session: WindowSession) -> Bool {
        finishedAllViewed(across: session.tabs.filter { $0.container.projectID == projectID })
    }

    private func finishedAllViewed(across scopedTabs: [Tab]) -> Bool {
        var sawFinished = false
        /// Returns false when this pane carries an *unviewed* finished
        /// turn (caller bails → green); otherwise notes any viewed
        /// finished. Claude / Codex badges are distinct types, so we feed
        /// each in separately.
        func check(_ state: AgentState, _ updatedAt: Date, _ paneID: UUID) -> Bool {
            guard state == .finished,
                  !isDismissed(paneID: paneID, badgeUpdatedAt: updatedAt)
            else { return true }
            if !isViewed(paneID: paneID, badgeUpdatedAt: updatedAt) { return false }
            sawFinished = true
            return true
        }
        for tab in scopedTabs {
            for paneID in tab.splitTree.allLeafIDs() {
                if let b = tab.claudeAgentBadges[paneID],
                   !check(b.state, b.updatedAt, paneID) { return false }
                if let b = tab.codexAgentBadges[paneID],
                   !check(b.state, b.updatedAt, paneID) { return false }
            }
        }
        return sawFinished
    }
}

// MARK: - Attention list + cursor

@MainActor
extension AttentionState {
    /// Public, `Identifiable` view of one waiting target so the container column
    /// Waiting list can render it in the same order the ⌘J cursor
    /// walks. `id` is the pane id — one entry per pane.
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
        /// Focus has visited this finished turn — render the row faded
        /// ("seen, not yet replied"). Always false for needsInput / error.
        let isViewed: Bool
        var id: UUID {
            paneID
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
        /// Pre-computed so the sort comparator can stay self-contained.
        let isViewed: Bool
    }

    /// Per-pane agent info (state + when + last prompt) from whichever
    /// integration owns it. A pane runs either Claude or Codex; if both
    /// carry a badge the higher-priority one wins so a blocked pane is
    /// never under-reported.
    private struct AttentionInfo {
        let state: AgentState
        let updatedAt: Date
        let lastPrompt: String?
        let detail: String?
    }

    private static func attentionInfo(in tab: Tab, paneID: UUID) -> AttentionInfo? {
        let claude = tab.claudeAgentBadges[paneID].map {
            AttentionInfo(state: $0.state, updatedAt: $0.updatedAt, lastPrompt: $0.lastPrompt, detail: $0.detail)
        }
        let codex = tab.codexAgentBadges[paneID].map {
            AttentionInfo(state: $0.state, updatedAt: $0.updatedAt, lastPrompt: $0.lastPrompt, detail: $0.detail)
        }
        switch (claude, codex) {
        case let (c?, x?):
            // Strictly higher priority wins (error > needsInput >
            // finished > running > idle). On equal priority — most
            // commonly both `.finished` on the same pane after the user
            // ran both agents in the same shell — pick the newer
            // updatedAt so the visible stamp matches reality. Picking
            // the older one would let a stale Claude badge hide a
            // freshly-finished Codex turn (or vice versa), and because
            // `dismissedAt` is keyed per pane, dismissing the visible
            // row would also mute the other agent's later turn until it
            // updates again.
            if c.state.priority > x.state.priority { return c }
            if x.state.priority > c.state.priority { return x }
            return c.updatedAt >= x.updatedAt ? c : x
        case let (c?, nil): return c
        case let (nil, x?): return x
        case (nil, nil): return nil
        }
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
        for tab in session.tabs {
            for paneID in tab.splitTree.allLeafIDs() {
                guard let info = Self.attentionInfo(in: tab, paneID: paneID),
                      info.state == .needsInput || info.state == .error || info.state == .finished
                else { continue }
                // A finished turn the user has explicitly dismissed drops
                // off the list. Viewing (focus visit) only fades the row.
                // needsInput / error are never dismissed this way.
                if info.state == .finished,
                   isDismissed(paneID: paneID, badgeUpdatedAt: info.updatedAt)
                { continue }
                let viewedNow = info.state == .finished
                    && isViewed(paneID: paneID, badgeUpdatedAt: info.updatedAt)
                targets.append(AttentionTarget(
                    tabID: tab.id,
                    paneID: paneID,
                    state: info.state,
                    updatedAt: info.updatedAt,
                    lastPrompt: info.lastPrompt,
                    detail: info.detail,
                    isViewed: viewedNow
                ))
            }
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
                isViewed: $0.isViewed
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
        }
        let target: AttentionTarget
        if let index = currentIndex {
            let step = forward ? 1 : -1
            target = ordered[(index + step + ordered.count) % ordered.count]
        } else {
            target = forward ? ordered[0] : ordered[ordered.count - 1]
        }
        PaneActions.activateAndFocus(session, registry: registry, tabID: target.tabID, paneID: target.paneID)
    }

    /// Jump straight to a specific target — used by the container column
    /// Waiting list when the user clicks a row.
    func focusAttention(
        in session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID
    ) {
        PaneActions.activateAndFocus(session, registry: registry, tabID: tabID, paneID: paneID)
    }
}
