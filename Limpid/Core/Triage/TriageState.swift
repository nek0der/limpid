// TriageState.swift
// Limpid — cross-pane triage state ("the ring") driving the L1
// WAITING list, the ⌘J cursor, and the finished-turn viewed → fade
// → dismissed lifecycle.
//
// Held independently of `WindowSession` because triage is a UI / workflow
// layer over the raw agent badges: `WindowSession` owns the
// Claude/Codex lifecycle facts; `TriageState` decides what the user is
// still being asked to deal with (and what's "seen, not yet replied").
// `WindowSession` stays a session-state hub; `TriageState` is the
// dedicated owner of `viewed` / `dismissed` plus the derivations and
// actions that read them.
//
// Wired via `@Environment(TriageState.self)` from `AppState`.

import Foundation

@MainActor
@Observable
final class TriageState {
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

    /// L1 WAITING list filter — when false, viewed-finished rows are
    /// hidden so the list shows only "next to deal with". `needsInput` /
    /// `error` are never hidden (they always demand a response). Session-
    /// scoped (not persisted) so the user starts each launch with the
    /// fuller picture.
    var includeViewed: Bool = true

    // MARK: - Mutation

    /// Manually dismiss a pane's *finished* turn ("conversation's done")
    /// so it drops off the WAITING list + clears the L1 / L2 check.
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

    /// Drop a pane's triage state (call when the pane closes) so the
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
    /// stamp. The L1 / L2 aggregate skips these so a dismissed pane
    /// stops contributing to its container's badge.
    private func isFinishedAndDismissed(paneID: UUID, state: AgentState, updatedAt: Date) -> Bool {
        state == .finished && isDismissed(paneID: paneID, badgeUpdatedAt: updatedAt)
    }
}

// MARK: - Aggregate AgentState (dismissed-filtered)

@MainActor
extension TriageState {
    /// Every observed agent state for a tab's panes (Claude + Codex
    /// merged), with any dismissed-finished turns filtered out so a
    /// finished pane the user has dismissed stops contributing to the
    /// L1 / L2 aggregate badge — same "dismissed → gone" rule the
    /// WAITING list uses. Live-agent / close-confirmation predicates
    /// on `WindowSession` read raw badges and are intentionally NOT
    /// filtered through here (a dismissed-finished pane is still a live
    /// session worth confirming before close).
    private func allAgentStates(in tab: Tab) -> [AgentState] {
        var states: [AgentState] = []
        for paneID in tab.splitTree.allLeafIDs() {
            if let b = tab.claudeAgentBadges[paneID],
               !isFinishedAndDismissed(paneID: paneID, state: b.state, updatedAt: b.updatedAt)
            {
                states.append(b.state)
            }
            if let b = tab.codexAgentBadges[paneID],
               !isFinishedAndDismissed(paneID: paneID, state: b.state, updatedAt: b.updatedAt)
            {
                states.append(b.state)
            }
        }
        return states
    }

    /// Aggregate state for a single tab — drives the L2 row badge.
    func aggregateAgentState(in tab: Tab) -> AgentState? {
        allAgentStates(in: tab).aggregateAgentState()
    }

    /// Aggregate across every tab in the given container — L1 group /
    /// project / worktree row badge.
    func aggregateAgentState(in container: ContainerID, session: WindowSession) -> AgentState? {
        session.tabs(in: container).flatMap { allAgentStates(in: $0) }.aggregateAgentState()
    }

    /// Aggregate across project-direct + every worktree inside the
    /// project. Used by Project headers in L1.
    func aggregateAgentStateInProject(_ projectID: UUID, session: WindowSession) -> AgentState? {
        session.tabs
            .filter { $0.container.projectID == projectID }
            .flatMap { allAgentStates(in: $0) }
            .aggregateAgentState()
    }

    /// Per-state pane counts for the L1 hover tooltip
    /// (`"1 error · 2 needsInput · 1 finished · 3 idle"`). Both Claude
    /// and Codex panes contribute; dismissed finished panes drop out.
    func agentStateBreakdown(in container: ContainerID, session: WindowSession) -> [AgentState: Int] {
        var out: [AgentState: Int] = [:]
        for tab in session.tabs(in: container) {
            for state in allAgentStates(in: tab) {
                out[state, default: 0] += 1
            }
        }
        return out
    }

    /// Same as the container variant but keyed off `Project.id`.
    func agentStateBreakdownInProject(_ projectID: UUID, session: WindowSession) -> [AgentState: Int] {
        var out: [AgentState: Int] = [:]
        for tab in session.tabs where tab.container.projectID == projectID {
            for state in allAgentStates(in: tab) {
                out[state, default: 0] += 1
            }
        }
        return out
    }

    // MARK: Aggregate viewed (drives grey vs green check)

    /// Whether a scope's `.finished` contribution is entirely *viewed* —
    /// drives the grey (vs green) L1 / L2 check. True only when there is
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
extension TriageState {
    /// Public, `Identifiable` view of one waiting target so the L1
    /// WAITING list can render it in the same order the ⌘J cursor
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
        case let (c?, x?): return c.state.priority >= x.state.priority ? c : x
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
    /// viewed flag). Both the L1 list and the ⌘J cursor follow this
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
                // unviewed (false) sorts before viewed (true) — the
                // user's "next to deal with" stays at the top of the tier.
                return !a.isViewed
            }
            return a.updatedAt < b.updatedAt
        }
    }

    /// `attentionTargets` after the `includeViewed` filter — the single
    /// source of truth for the visible WAITING list and the ⌘J cursor,
    /// so the cursor never lands on a row the user can't see. With the
    /// filter on (default) this matches `attentionTargets`; with it off,
    /// viewed-finished rows drop out (needsInput / error are never
    /// filtered — they always demand a response).
    private func visibleAttentionTargets(in session: WindowSession) -> [AttentionTarget] {
        attentionTargets(in: session)
            .filter { includeViewed || !($0.state == .finished && $0.isViewed) }
    }

    /// Count of finished panes the `includeViewed` filter is currently
    /// hiding. Used by the L1 WAITING region to render a small
    /// "N hidden" hint when the filter is on and the visible list is
    /// otherwise empty. Returns 0 when the filter is off.
    func hiddenViewedCount(in session: WindowSession) -> Int {
        guard !includeViewed else { return 0 }
        return attentionTargets(in: session)
            .count(where: { $0.state == .finished && $0.isViewed })
    }

    /// Ordered entries for the L1 WAITING list — same order
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
    /// visible list the L1 WAITING region renders, so toggling the
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
        TabActions.activateAndFocus(session, registry: registry, tabID: target.tabID, paneID: target.paneID)
    }

    /// Jump straight to a specific target — used by the L1
    /// WAITING list when the user clicks a row.
    func focusAttention(
        in session: WindowSession,
        registry: any SurfaceViewProviding,
        tabID: UUID,
        paneID: UUID
    ) {
        TabActions.activateAndFocus(session, registry: registry, tabID: tabID, paneID: paneID)
    }
}
