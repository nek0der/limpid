// AttentionStateTests.swift
// Limpid — unit tests for `AttentionState`: WAITING list membership, severity-then-age order, viewed fade, and dismissed drop.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AttentionStateTests {
    /// Build a Claude badge in a given state stamped at `epoch` seconds.
    private func badge(_ state: AgentState, at epoch: TimeInterval) -> ClaudeAgentBadge {
        ClaudeAgentBadge(
            state: state,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: epoch),
            lastPrompt: nil
        )
    }

    /// Add a fresh loose tab carrying one pane with the given Claude
    /// badge; returns the pane id.
    private func paneWithBadge(
        _ session: WindowSession,
        _ state: AgentState,
        at epoch: TimeInterval
    ) -> UUID {
        let tab = session.openTab(container: .loose)
        let paneID = tab.splitTree.allLeafIDs().first!
        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(state, at: epoch) }
        return paneID
    }

    @Test func attentionEntries_includesWaitingStates_excludesRunningAndIdle() {
        let session = WindowSession()
        let attention = AttentionState()
        let needs = paneWithBadge(session, .needsInput, at: 100)
        let err = paneWithBadge(session, .error, at: 100)
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 100)
        _ = paneWithBadge(session, .idle, at: 100)

        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [needs, err, done])
    }

    @Test func attentionEntries_withinSeverityTier_ordersOldestFirst() {
        let session = WindowSession()
        let attention = AttentionState()
        // All same severity so only age decides — peers accumulate FIFO.
        let newest = paneWithBadge(session, .finished, at: 300)
        let oldest = paneWithBadge(session, .finished, at: 100)
        let middle = paneWithBadge(session, .finished, at: 200)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [oldest, middle, newest])
    }

    /// Regression guard: when both Claude and Codex carry `.finished`
    /// on the same pane, the visible badge has to track the newer of
    /// the two so a stale Claude stamp can't hide a freshly-finished
    /// Codex turn. The earlier tiebreak (Claude wins by `>=`) hid the
    /// newer Codex stamp and made dismissing the visible row mute the
    /// newer turn until it updated again.
    @Test func attentionEntries_codexFinishedNewerThanClaude_surfaceUsesCodexStamp() throws {
        let session = WindowSession()
        let attention = AttentionState()
        let tab = session.openTab(container: .loose)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let claudeStamp = Date(timeIntervalSince1970: 100)
        let codexStamp = Date(timeIntervalSince1970: 200)
        session.update(tab.id) {
            $0.claudeAgentBadges[pane] = AgentBadge(
                state: .finished, detail: nil, runStartedAt: nil,
                contextTokens: nil, updatedAt: claudeStamp, lastPrompt: nil
            )
            $0.codexAgentBadges[pane] = AgentBadge(
                state: .finished, detail: nil, runStartedAt: nil,
                contextTokens: nil, updatedAt: codexStamp, lastPrompt: nil
            )
        }
        let entry = try #require(attention.attentionEntries(in: session).first)
        #expect(entry.updatedAt == codexStamp)
    }

    @Test func attentionEntries_finishedTier_unviewedFloatsAboveViewed() {
        let session = WindowSession()
        let attention = AttentionState()
        // Older finished that the user has already glanced at — should
        // sink below the newer-but-unseen one. "Next to deal with" goes
        // up.
        let oldSeen = paneWithBadge(session, .finished, at: 100)
        let newUnseen = paneWithBadge(session, .finished, at: 200)
        attention.focusMoved(to: oldSeen, in: session)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [newUnseen, oldSeen])
    }

    @Test func attentionEntries_ordersBySeverity_beforeAge() {
        let session = WindowSession()
        let attention = AttentionState()
        // The error is newest and the finished oldest — severity must
        // still float the error to the top so it can't hide below an
        // older finished turn.
        let finishedOld = paneWithBadge(session, .finished, at: 100)
        let needsMid = paneWithBadge(session, .needsInput, at: 200)
        let errorNew = paneWithBadge(session, .error, at: 300)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [errorNew, needsMid, finishedOld])
    }

    @Test func dismiss_dropsFinishedPaneFromList() {
        let session = WindowSession()
        let attention = AttentionState()
        let done = paneWithBadge(session, .finished, at: 100)
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == done })

        attention.dismiss(paneID: done, in: session)

        #expect(!attention.attentionEntries(in: session).contains { $0.paneID == done })
    }

    @Test func dismiss_doesNotAffectNeedsInput() {
        let session = WindowSession()
        let attention = AttentionState()
        let needs = paneWithBadge(session, .needsInput, at: 100)

        attention.dismiss(paneID: needs, in: session)

        // needsInput must persist until the underlying state resolves —
        // dismiss is a no-op against anything but `.finished`.
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == needs })
    }

    @Test func dismissedFinished_resurfacesOnNewerFinishedTurn() throws {
        let session = WindowSession()
        let attention = AttentionState()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 100) }
        attention.dismiss(paneID: paneID, in: session)
        #expect(!attention.attentionEntries(in: session).contains { $0.paneID == paneID })

        // A later finished turn (greater updatedAt) is a new event and
        // must reappear despite the earlier dismiss.
        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 200) }
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == paneID })
    }

    @Test func focusMoved_marksFinishedAsViewed_butKeepsItInTheList() {
        let session = WindowSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, .finished, at: 100)

        attention.focusMoved(to: pane, in: session)

        // Viewing is not completing: the row stays listed, but flagged
        // viewed so the UI can fade it.
        let entry = attention.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry != nil)
        #expect(entry?.isViewed == true)
    }

    @Test func focusMoved_doesNotMarkNeedsInputAsViewed() {
        let session = WindowSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, .needsInput, at: 100)

        attention.focusMoved(to: pane, in: session)

        // Only finished turns carry the viewed state; needsInput stays at
        // full strength until it actually resolves.
        let entry = attention.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry?.isViewed == false)
    }

    @Test func aggregateViewed_focusedPaneMarkedAfterBadgeArrives() throws {
        // Models the "running → finished on the pane I'm looking at"
        // path: focus is on the pane, then a finished badge lands, then
        // the tracker calls `markViewed` (the production wiring lives
        // in ClaudeAgentStateTracker.applyAllRecordsToSession). The
        // WAITING entry should be viewed (gray) the moment that fires.
        let session = WindowSession()
        let attention = AttentionState()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.setActiveTab(tab.id)

        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 100) }
        // Tracker's auto-mark — mirrors the production call site.
        attention.markViewed(paneID: paneID, in: session)

        let entry = attention.attentionEntries(in: session).first { $0.paneID == paneID }
        #expect(entry?.isViewed == true)
        // Re-fetch the tab so we see the post-update badges (the local
        // `tab` above is a value-type snapshot taken before the badge
        // landed).
        let updatedTab = try #require(session.tab(tab.id))
        #expect(attention.isFinishedAggregateViewed(in: updatedTab))
    }

    @Test func includeViewed_false_hidesViewedFinishedButKeepsNeedsInput() {
        let session = WindowSession()
        let attention = AttentionState()
        let seen = paneWithBadge(session, .finished, at: 100)
        let unseen = paneWithBadge(session, .finished, at: 200)
        let needs = paneWithBadge(session, .needsInput, at: 300)
        attention.focusMoved(to: seen, in: session)

        attention.includeViewed = false
        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        // Viewed-finished hidden; unviewed-finished + needsInput kept.
        // needsInput / error are NEVER hidden by the toggle.
        #expect(ids == [unseen, needs])
    }

    @Test func hiddenViewedCount_reportsFilteredFinishedCount() {
        let session = WindowSession()
        let attention = AttentionState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        _ = paneWithBadge(session, .needsInput, at: 300)
        attention.focusMoved(to: a, in: session)
        attention.focusMoved(to: b, in: session)

        // Filter off → nothing hidden.
        #expect(attention.hiddenViewedCount(in: session) == 0)
        // Filter on → both viewed-finished are hidden, needsInput isn't
        // counted (it was never a viewed-finished candidate).
        attention.includeViewed = false
        #expect(attention.hiddenViewedCount(in: session) == 2)
    }

    @Test func forget_dropsAttentionBookkeepingForClosedPane() {
        let session = WindowSession()
        let attention = AttentionState()
        let pane = paneWithBadge(session, .finished, at: 100)
        attention.focusMoved(to: pane, in: session)
        attention.dismiss(paneID: pane, in: session)
        // Both dicts have the entry now.
        #expect(attention.viewedAt[pane] != nil)
        #expect(attention.dismissedAt[pane] != nil)

        attention.forget(paneID: pane)
        #expect(attention.viewedAt[pane] == nil)
        #expect(attention.dismissedAt[pane] == nil)
    }

    @Test func includeViewed_true_isTheDefaultAndShowsEverything() {
        let session = WindowSession()
        let attention = AttentionState()
        let seen = paneWithBadge(session, .finished, at: 100)
        let unseen = paneWithBadge(session, .finished, at: 200)
        attention.focusMoved(to: seen, in: session)

        // Default value of includeViewed → both rows visible.
        #expect(attention.includeViewed)
        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [seen, unseen])
    }

    @Test func sweepingWithFocus_keepsEveryFinishedTurnListed() {
        let session = WindowSession()
        let attention = AttentionState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        // ⌘J fly-by across both: focus visits each, but nothing drops —
        // peeking never completes a turn.
        attention.focusMoved(to: a, in: session)
        attention.focusMoved(to: b, in: session)

        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        #expect(ids.contains(a))
        #expect(ids.contains(b))
    }

    @Test func severityBeatsViewed_errorAboveUnviewedFinished() {
        let session = WindowSession()
        let attention = AttentionState()
        // An error always tops the list — even if the only finished pane
        // in the list is unseen. Severity is the primary axis; viewed is
        // a tiebreaker within a tier.
        let unseenFinished = paneWithBadge(session, .finished, at: 100)
        let err = paneWithBadge(session, .error, at: 200)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [err, unseenFinished])
    }

    // MARK: - Aggregate viewed (drives the container / tab column gray vs green check)

    @Test func aggregateViewed_allFinishedViewed_returnsTrue() {
        let session = WindowSession()
        let attention = AttentionState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        attention.focusMoved(to: a, in: session)
        attention.focusMoved(to: b, in: session)

        #expect(attention.isFinishedAggregateViewed(in: .loose, session: session))
    }

    @Test func aggregateViewed_oneFinishedUnviewed_returnsFalse() {
        let session = WindowSession()
        let attention = AttentionState()
        let a = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .finished, at: 200)

        // Only `a` is viewed; the other finished pane keeps the
        // aggregate green.
        attention.focusMoved(to: a, in: session)

        #expect(attention.isFinishedAggregateViewed(in: .loose, session: session) == false)
    }

    @Test func aggregateViewed_noFinishedPanes_returnsFalse() {
        let session = WindowSession()
        let attention = AttentionState()
        _ = paneWithBadge(session, .needsInput, at: 100)
        _ = paneWithBadge(session, .running, at: 100)

        // "All finished panes are viewed" is vacuously true with zero
        // finished panes, but we return false so the caller doesn't
        // gray out a check that's lit by needsInput / error / running.
        #expect(attention.isFinishedAggregateViewed(in: .loose, session: session) == false)
    }

    // MARK: - Aggregate AgentState (drives container / tab column badge icon)

    @Test func aggregateAgentState_runningOutranksViewedFinished() {
        // The bug this fixes: a container shows the gray check (viewed
        // `.finished`) even while a sibling pane is still `.running`.
        // Once the user has glanced at the finished turn, the running
        // sibling should be what the container / tab column badge advertises.
        let session = WindowSession()
        let attention = AttentionState()
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)
        attention.focusMoved(to: done, in: session)

        #expect(attention.aggregateAgentState(in: .loose, session: session) == .running)
    }

    @Test func aggregateAgentState_runningStaysBelowUnviewedFinished() {
        // Unviewed `.finished` still outranks `.running` — the user
        // hasn't seen the check yet, so we keep the green dot.
        let session = WindowSession()
        let attention = AttentionState()
        _ = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)

        #expect(attention.aggregateAgentState(in: .loose, session: session) == .finished)
    }

    @Test func aggregateAgentState_onlyViewedFinished_stillShowsCheck() {
        // No other state present — the gray check stays so the row
        // doesn't go silent on "all viewed".
        let session = WindowSession()
        let attention = AttentionState()
        let done = paneWithBadge(session, .finished, at: 100)
        attention.focusMoved(to: done, in: session)

        #expect(attention.aggregateAgentState(in: .loose, session: session) == .finished)
    }

    @Test func aggregateAgentState_errorBeatsViewedFinishedAndRunning() {
        // Severity still wins above the running/viewed-finished
        // tiebreaker — an error must surface no matter what else sits
        // in the container.
        let session = WindowSession()
        let attention = AttentionState()
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)
        _ = paneWithBadge(session, .error, at: 300)
        attention.focusMoved(to: done, in: session)

        #expect(attention.aggregateAgentState(in: .loose, session: session) == .error)
    }

    @Test func aggregateViewed_dismissedFinishedExcluded() {
        let session = WindowSession()
        let attention = AttentionState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        // `b` viewed; `a` dismissed → dismissed panes drop out of the
        // aggregate entirely, so the remaining set (just `b`) is fully
        // viewed → true.
        attention.dismiss(paneID: a, in: session)
        attention.focusMoved(to: b, in: session)

        #expect(attention.isFinishedAggregateViewed(in: .loose, session: session))
    }

    // MARK: - ⌘J cursor honours the includeViewed filter

    @Test func jumpToAttention_includeViewedFalse_skipsViewedFinished() throws {
        let session = WindowSession()
        let attention = AttentionState()
        let registry = NoopSurfaceRegistry()
        // Three finished panes; mark the middle one viewed and hide
        // viewed-finished. The cursor must walk only the two visible
        // unviewed panes, not stop on the hidden one.
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        let c = paneWithBadge(session, .finished, at: 300)
        attention.focusMoved(to: b, in: session)
        attention.includeViewed = false

        // Park focus on `a` so the cursor has a known starting point.
        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)

        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)

        // Forward again wraps inside the visible subset back to `a` —
        // the hidden `b` is skipped on the wrap as well.
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == a)
    }

    @Test func jumpToAttention_includeViewedTrue_walksEveryWaitingPane() throws {
        let session = WindowSession()
        let attention = AttentionState()
        let registry = NoopSurfaceRegistry()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        let c = paneWithBadge(session, .finished, at: 300)
        // `b` is viewed but the filter is on — viewed rows stay
        // reachable so the cursor behavior matches what the list shows.
        attention.focusMoved(to: b, in: session)

        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)

        // List order is unviewed-first within the finished tier (c, a, b).
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == b)
    }

    @Test func jumpToAttention_filterHidesEveryRow_isNoOp() throws {
        let session = WindowSession()
        let attention = AttentionState()
        let registry = NoopSurfaceRegistry()
        // Only one waiting pane and it's already viewed. With the filter
        // off the visible list is empty → ⌘J has nowhere to go and must
        // leave focus untouched rather than stepping into hidden rows.
        let pane = paneWithBadge(session, .finished, at: 100)
        attention.focusMoved(to: pane, in: session)
        attention.includeViewed = false

        let other = session.openTab(container: .loose)
        let otherPane = try #require(other.splitTree.allLeafIDs().first)
        session.setActiveTab(other.id)

        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTabID == other.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == otherPane)
    }
}
