// TriageRingTests.swift
// Limpid — unit tests for the cross-pane attention ("triage ring")
// model logic on `TriageState`: which panes surface in the WAITING
// list, their severity-then-age order, the viewed (fade) state from
// focus visits, and the dismissed (drop) state from the explicit ×.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct TriageRingTests {
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
        let triage = TriageState()
        let needs = paneWithBadge(session, .needsInput, at: 100)
        let err = paneWithBadge(session, .error, at: 100)
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 100)
        _ = paneWithBadge(session, .idle, at: 100)

        let ids = Set(triage.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [needs, err, done])
    }

    @Test func attentionEntries_withinSeverityTier_ordersOldestFirst() {
        let session = WindowSession()
        let triage = TriageState()
        // All same severity so only age decides — peers accumulate FIFO.
        let newest = paneWithBadge(session, .finished, at: 300)
        let oldest = paneWithBadge(session, .finished, at: 100)
        let middle = paneWithBadge(session, .finished, at: 200)

        let order = triage.attentionEntries(in: session).map(\.paneID)
        #expect(order == [oldest, middle, newest])
    }

    @Test func attentionEntries_finishedTier_unviewedFloatsAboveViewed() {
        let session = WindowSession()
        let triage = TriageState()
        // Older finished that the user has already glanced at — should
        // sink below the newer-but-unseen one. "Next to deal with" goes
        // up.
        let oldSeen = paneWithBadge(session, .finished, at: 100)
        let newUnseen = paneWithBadge(session, .finished, at: 200)
        triage.focusMoved(to: oldSeen, in: session)

        let order = triage.attentionEntries(in: session).map(\.paneID)
        #expect(order == [newUnseen, oldSeen])
    }

    @Test func attentionEntries_ordersBySeverity_beforeAge() {
        let session = WindowSession()
        let triage = TriageState()
        // The error is newest and the finished oldest — severity must
        // still float the error to the top so it can't hide below an
        // older finished turn.
        let finishedOld = paneWithBadge(session, .finished, at: 100)
        let needsMid = paneWithBadge(session, .needsInput, at: 200)
        let errorNew = paneWithBadge(session, .error, at: 300)

        let order = triage.attentionEntries(in: session).map(\.paneID)
        #expect(order == [errorNew, needsMid, finishedOld])
    }

    @Test func dismiss_dropsFinishedPaneFromList() {
        let session = WindowSession()
        let triage = TriageState()
        let done = paneWithBadge(session, .finished, at: 100)
        #expect(triage.attentionEntries(in: session).contains { $0.paneID == done })

        triage.dismiss(paneID: done, in: session)

        #expect(!triage.attentionEntries(in: session).contains { $0.paneID == done })
    }

    @Test func dismiss_doesNotAffectNeedsInput() {
        let session = WindowSession()
        let triage = TriageState()
        let needs = paneWithBadge(session, .needsInput, at: 100)

        triage.dismiss(paneID: needs, in: session)

        // needsInput must persist until the underlying state resolves —
        // dismiss is a no-op against anything but `.finished`.
        #expect(triage.attentionEntries(in: session).contains { $0.paneID == needs })
    }

    @Test func dismissedFinished_resurfacesOnNewerFinishedTurn() throws {
        let session = WindowSession()
        let triage = TriageState()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)

        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 100) }
        triage.dismiss(paneID: paneID, in: session)
        #expect(!triage.attentionEntries(in: session).contains { $0.paneID == paneID })

        // A later finished turn (greater updatedAt) is a new event and
        // must reappear despite the earlier dismiss.
        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 200) }
        #expect(triage.attentionEntries(in: session).contains { $0.paneID == paneID })
    }

    @Test func focusMoved_marksFinishedAsViewed_butKeepsItInTheList() {
        let session = WindowSession()
        let triage = TriageState()
        let pane = paneWithBadge(session, .finished, at: 100)

        triage.focusMoved(to: pane, in: session)

        // Viewing is not completing: the row stays listed, but flagged
        // viewed so the UI can fade it.
        let entry = triage.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry != nil)
        #expect(entry?.isViewed == true)
    }

    @Test func focusMoved_doesNotMarkNeedsInputAsViewed() {
        let session = WindowSession()
        let triage = TriageState()
        let pane = paneWithBadge(session, .needsInput, at: 100)

        triage.focusMoved(to: pane, in: session)

        // Only finished turns carry the viewed state; needsInput stays at
        // full strength until it actually resolves.
        let entry = triage.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry?.isViewed == false)
    }

    @Test func aggregateViewed_focusedPaneMarkedAfterBadgeArrives() throws {
        // Models the "running → finished on the pane I'm looking at"
        // path: focus is on the pane, then a finished badge lands, then
        // the tracker calls `markViewed` (the production wiring lives
        // in ClaudeAgentStateTracker.applyAllRecordsToSession). The
        // WAITING entry should be viewed (grey) the moment that fires.
        let session = WindowSession()
        let triage = TriageState()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        session.setActiveTab(tab.id)

        session.update(tab.id) { $0.claudeAgentBadges[paneID] = badge(.finished, at: 100) }
        // Tracker's auto-mark — mirrors the production call site.
        triage.markViewed(paneID: paneID, in: session)

        let entry = triage.attentionEntries(in: session).first { $0.paneID == paneID }
        #expect(entry?.isViewed == true)
        // Re-fetch the tab so we see the post-update badges (the local
        // `tab` above is a value-type snapshot taken before the badge
        // landed).
        let updatedTab = try #require(session.tab(tab.id))
        #expect(triage.isFinishedAggregateViewed(in: updatedTab))
    }

    @Test func includeViewed_false_hidesViewedFinishedButKeepsNeedsInput() {
        let session = WindowSession()
        let triage = TriageState()
        let seen = paneWithBadge(session, .finished, at: 100)
        let unseen = paneWithBadge(session, .finished, at: 200)
        let needs = paneWithBadge(session, .needsInput, at: 300)
        triage.focusMoved(to: seen, in: session)

        triage.includeViewed = false
        let ids = Set(triage.attentionEntries(in: session).map(\.paneID))
        // Viewed-finished hidden; unviewed-finished + needsInput kept.
        // needsInput / error are NEVER hidden by the toggle.
        #expect(ids == [unseen, needs])
    }

    @Test func hiddenViewedCount_reportsFilteredFinishedCount() {
        let session = WindowSession()
        let triage = TriageState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        _ = paneWithBadge(session, .needsInput, at: 300)
        triage.focusMoved(to: a, in: session)
        triage.focusMoved(to: b, in: session)

        // Filter off → nothing hidden.
        #expect(triage.hiddenViewedCount(in: session) == 0)
        // Filter on → both viewed-finished are hidden, needsInput isn't
        // counted (it was never a viewed-finished candidate).
        triage.includeViewed = false
        #expect(triage.hiddenViewedCount(in: session) == 2)
    }

    @Test func forget_dropsTriageBookkeepingForClosedPane() {
        let session = WindowSession()
        let triage = TriageState()
        let pane = paneWithBadge(session, .finished, at: 100)
        triage.focusMoved(to: pane, in: session)
        triage.dismiss(paneID: pane, in: session)
        // Both dicts have the entry now.
        #expect(triage.viewedAt[pane] != nil)
        #expect(triage.dismissedAt[pane] != nil)

        triage.forget(paneID: pane)
        #expect(triage.viewedAt[pane] == nil)
        #expect(triage.dismissedAt[pane] == nil)
    }

    @Test func includeViewed_true_isTheDefaultAndShowsEverything() {
        let session = WindowSession()
        let triage = TriageState()
        let seen = paneWithBadge(session, .finished, at: 100)
        let unseen = paneWithBadge(session, .finished, at: 200)
        triage.focusMoved(to: seen, in: session)

        // Default value of includeViewed → both rows visible.
        #expect(triage.includeViewed)
        let ids = Set(triage.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [seen, unseen])
    }

    @Test func sweepingWithFocus_keepsEveryFinishedTurnListed() {
        let session = WindowSession()
        let triage = TriageState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        // ⌘J fly-by across both: focus visits each, but nothing drops —
        // peeking never completes a turn.
        triage.focusMoved(to: a, in: session)
        triage.focusMoved(to: b, in: session)

        let ids = Set(triage.attentionEntries(in: session).map(\.paneID))
        #expect(ids.contains(a))
        #expect(ids.contains(b))
    }

    @Test func severityBeatsViewed_errorAboveUnviewedFinished() {
        let session = WindowSession()
        let triage = TriageState()
        // An error always tops the list — even if the only finished pane
        // in the list is unseen. Severity is the primary axis; viewed is
        // a tiebreaker within a tier.
        let unseenFinished = paneWithBadge(session, .finished, at: 100)
        let err = paneWithBadge(session, .error, at: 200)

        let order = triage.attentionEntries(in: session).map(\.paneID)
        #expect(order == [err, unseenFinished])
    }

    // MARK: - Aggregate viewed (drives the L1 / L2 grey vs green check)

    @Test func aggregateViewed_allFinishedViewed_returnsTrue() {
        let session = WindowSession()
        let triage = TriageState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        triage.focusMoved(to: a, in: session)
        triage.focusMoved(to: b, in: session)

        #expect(triage.isFinishedAggregateViewed(in: .loose, session: session))
    }

    @Test func aggregateViewed_oneFinishedUnviewed_returnsFalse() {
        let session = WindowSession()
        let triage = TriageState()
        let a = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .finished, at: 200)

        // Only `a` is viewed; the other finished pane keeps the
        // aggregate green.
        triage.focusMoved(to: a, in: session)

        #expect(triage.isFinishedAggregateViewed(in: .loose, session: session) == false)
    }

    @Test func aggregateViewed_noFinishedPanes_returnsFalse() {
        let session = WindowSession()
        let triage = TriageState()
        _ = paneWithBadge(session, .needsInput, at: 100)
        _ = paneWithBadge(session, .running, at: 100)

        // "All finished panes are viewed" is vacuously true with zero
        // finished panes, but we return false so the caller doesn't
        // grey out a check that's lit by needsInput / error / running.
        #expect(triage.isFinishedAggregateViewed(in: .loose, session: session) == false)
    }

    // MARK: - Aggregate AgentState (drives L1 / L2 badge icon)

    @Test func aggregateAgentState_runningOutranksViewedFinished() {
        // The bug this fixes: a container shows the grey check (viewed
        // `.finished`) even while a sibling pane is still `.running`.
        // Once the user has glanced at the finished turn, the running
        // sibling should be what the L1 / L2 badge advertises.
        let session = WindowSession()
        let triage = TriageState()
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)
        triage.focusMoved(to: done, in: session)

        #expect(triage.aggregateAgentState(in: .loose, session: session) == .running)
    }

    @Test func aggregateAgentState_runningStaysBelowUnviewedFinished() {
        // Unviewed `.finished` still outranks `.running` — the user
        // hasn't seen the check yet, so we keep the green dot.
        let session = WindowSession()
        let triage = TriageState()
        _ = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)

        #expect(triage.aggregateAgentState(in: .loose, session: session) == .finished)
    }

    @Test func aggregateAgentState_onlyViewedFinished_stillShowsCheck() {
        // No other state present — the grey check stays so the row
        // doesn't go silent on "all viewed".
        let session = WindowSession()
        let triage = TriageState()
        let done = paneWithBadge(session, .finished, at: 100)
        triage.focusMoved(to: done, in: session)

        #expect(triage.aggregateAgentState(in: .loose, session: session) == .finished)
    }

    @Test func aggregateAgentState_errorBeatsViewedFinishedAndRunning() {
        // Severity still wins above the running/viewed-finished
        // tiebreaker — an error must surface no matter what else sits
        // in the container.
        let session = WindowSession()
        let triage = TriageState()
        let done = paneWithBadge(session, .finished, at: 100)
        _ = paneWithBadge(session, .running, at: 200)
        _ = paneWithBadge(session, .error, at: 300)
        triage.focusMoved(to: done, in: session)

        #expect(triage.aggregateAgentState(in: .loose, session: session) == .error)
    }

    @Test func aggregateViewed_dismissedFinishedExcluded() {
        let session = WindowSession()
        let triage = TriageState()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)

        // `b` viewed; `a` dismissed → dismissed panes drop out of the
        // aggregate entirely, so the remaining set (just `b`) is fully
        // viewed → true.
        triage.dismiss(paneID: a, in: session)
        triage.focusMoved(to: b, in: session)

        #expect(triage.isFinishedAggregateViewed(in: .loose, session: session))
    }

    // MARK: - ⌘J cursor honours the includeViewed filter

    @Test func jumpToAttention_includeViewedFalse_skipsViewedFinished() throws {
        let session = WindowSession()
        let triage = TriageState()
        let registry = NoopSurfaceRegistry()
        // Three finished panes; mark the middle one viewed and hide
        // viewed-finished. The cursor must walk only the two visible
        // unviewed panes, not stop on the hidden one.
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        let c = paneWithBadge(session, .finished, at: 300)
        triage.focusMoved(to: b, in: session)
        triage.includeViewed = false

        // Park focus on `a` so the cursor has a known starting point.
        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)

        triage.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)

        // Forward again wraps inside the visible subset back to `a` —
        // the hidden `b` is skipped on the wrap as well.
        triage.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == a)
    }

    @Test func jumpToAttention_includeViewedTrue_walksEveryWaitingPane() throws {
        let session = WindowSession()
        let triage = TriageState()
        let registry = NoopSurfaceRegistry()
        let a = paneWithBadge(session, .finished, at: 100)
        let b = paneWithBadge(session, .finished, at: 200)
        let c = paneWithBadge(session, .finished, at: 300)
        // `b` is viewed but the filter is on — viewed rows stay
        // reachable so the cursor behaviour matches what the list shows.
        triage.focusMoved(to: b, in: session)

        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)

        // List order is unviewed-first within the finished tier (c, a, b).
        triage.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)
        triage.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == b)
    }

    @Test func jumpToAttention_filterHidesEveryRow_isNoOp() throws {
        let session = WindowSession()
        let triage = TriageState()
        let registry = NoopSurfaceRegistry()
        // Only one waiting pane and it's already viewed. With the filter
        // off the visible list is empty → ⌘J has nowhere to go and must
        // leave focus untouched rather than stepping into hidden rows.
        let pane = paneWithBadge(session, .finished, at: 100)
        triage.focusMoved(to: pane, in: session)
        triage.includeViewed = false

        let other = session.openTab(container: .loose)
        let otherPane = try #require(other.splitTree.allLeafIDs().first)
        session.setActiveTab(other.id)

        triage.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTabID == other.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == otherPane)
    }
}
