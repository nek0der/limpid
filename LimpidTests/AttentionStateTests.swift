// AttentionStateTests.swift
// Limpid — unit tests for `AttentionState`: Waiting membership,
// severity-then-age order, viewed acknowledgement, and dismissed drop.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct AttentionStateTests {
    /// Build a Claude badge in a given state stamped at `epoch` seconds.
    private func badge(
        _ state: AgentState,
        at epoch: TimeInterval,
        turnBaseTree: String? = nil,
        turnRoot: String? = nil
    ) -> ClaudeAgentBadge {
        ClaudeAgentBadge(
            state: state,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSince1970: epoch),
            lastPrompt: nil,
            turnBaseTree: turnBaseTree,
            turnRoot: turnRoot
        )
    }

    /// Attention state whose clock sits shortly after the small epochs
    /// the badges below use. Badges are stamped at 1970 for readability,
    /// so with the wall clock every viewed finished turn would already
    /// be past `viewedFinishedRetention` and vanish; the retention tests
    /// move `now` explicitly where the ceiling is the subject.
    private func makeAttention() -> AttentionState {
        let attention = AttentionState()
        attention.now = { Date(timeIntervalSince1970: 10000) }
        return attention
    }

    /// Add a fresh loose tab carrying one pane with the given Claude
    /// badge; returns the pane id. Waiting rows come only from the
    /// runtime projection, so the helper publishes a matching Claude
    /// runtime as well as writing the session badge.
    private func paneWithBadge(
        _ session: WindowSession,
        _ attention: AttentionState,
        _ state: AgentState,
        at epoch: TimeInterval
    ) -> UUID {
        let tab = session.openTab(container: .loose)
        let paneID = tab.splitTree.allLeafIDs().first!
        setBadge(session, attention, paneID: paneID, state, at: epoch)
        return paneID
    }

    /// The runtime id `paneWithBadge` publishes for a pane. The run id is
    /// derived from the pane id so a test can address the runtime without
    /// threading an extra identifier through every helper.
    private func runtimeID(for paneID: UUID) -> String {
        AgentRuntimePresentation.id(kind: .claude, runID: paneID.uuidString)
    }

    /// Write a pane's Claude badge and republish its runtime. The episode
    /// token folds in the stamp, so restating a pane at a later epoch is a
    /// new attention episode and clears any earlier viewed / dismissed mark.
    private func setBadge(
        _ session: WindowSession,
        _ attention: AttentionState,
        paneID: UUID,
        _ state: AgentState,
        at epoch: TimeInterval,
        turnBaseTree: String? = nil,
        turnRoot: String? = nil
    ) {
        let written = badge(state, at: epoch, turnBaseTree: turnBaseTree, turnRoot: turnRoot)
        if let tab = session.tab(containing: paneID) {
            session.update(tab.id) { $0.agentBadges[.claude, default: [:]][paneID] = written }
        }
        let runtime = AgentRuntimePresentation(
            kind: .claude,
            runID: paneID.uuidString,
            revision: Int(epoch),
            badge: written,
            paneIDs: [paneID],
            tmuxLocations: [:],
            stateEpisodeToken: "\(paneID.uuidString):\(epoch)"
        )
        let others = (attention.runtimesByKind[.claude] ?? []).filter { $0.runID != paneID.uuidString }
        attention.replaceRuntimes(others + [runtime], kind: .claude)
    }

    private func runtime(
        _ state: AgentState,
        paneID: UUID,
        revision: Int,
        episode: String
    ) -> AgentRuntimePresentation {
        AgentRuntimePresentation(
            kind: .codex,
            runID: "run",
            revision: revision,
            badge: AgentBadge(
                state: state,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(revision))
            ),
            paneIDs: [paneID],
            tmuxLocations: [:],
            stateEpisodeToken: episode
        )
    }

    @Test func attentionEntries_includesWaitingStates_excludesRunningAndIdle() {
        let session = WindowSession()
        let attention = makeAttention()
        let needs = paneWithBadge(session, attention, .needsInput, at: 100)
        let err = paneWithBadge(session, attention, .error, at: 100)
        let done = paneWithBadge(session, attention, .finished, at: 100)
        _ = paneWithBadge(session, attention, .running, at: 100)
        _ = paneWithBadge(session, attention, .idle, at: 100)

        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [needs, err, done])
    }

    @Test func attentionEntries_withinSeverityTier_ordersOldestFirst() {
        let session = WindowSession()
        let attention = makeAttention()
        // All same severity so only age decides — peers accumulate FIFO.
        let newest = paneWithBadge(session, attention, .finished, at: 300)
        let oldest = paneWithBadge(session, attention, .finished, at: 100)
        let middle = paneWithBadge(session, attention, .finished, at: 200)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [oldest, middle, newest])
    }

    /// Entries are keyed by runtime, not by pane: a pane where the user
    /// ran both Claude and Codex in the same shell lists both finished
    /// turns. Keying by pane would collapse them into one row, hide a
    /// freshly finished Codex turn behind a stale Claude stamp, and let one
    /// dismiss mute both.
    @Test func attentionEntries_claudeAndCodexOnOnePane_listBothRuntimes() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .finished, at: 200)
        let codexID = AgentRuntimePresentation.id(kind: .codex, runID: "run")
        attention.replaceRuntimes(
            [runtime(.finished, paneID: pane, revision: 100, episode: "codex-100")],
            kind: .codex
        )

        // Oldest first inside the finished tier, so the Codex turn
        // (stamped at 100) leads the newer Claude one (200).
        let entries = attention.attentionEntries(in: session)
        #expect(entries.map(\.runtimeID) == [codexID, runtimeID(for: pane)])
    }

    @Test func attentionEntries_finishedTier_unviewedFloatsAboveViewed() {
        let session = WindowSession()
        let attention = makeAttention()
        // Older finished that the user has already glanced at — should
        // sink below the newer-but-unseen one. "Next to deal with" goes
        // up.
        let oldSeen = paneWithBadge(session, attention, .finished, at: 100)
        let newUnseen = paneWithBadge(session, attention, .finished, at: 200)
        attention.focusMoved(to: oldSeen, in: session)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [newUnseen, oldSeen])
    }

    @Test func attentionEntries_ordersBySeverity_beforeAge() {
        let session = WindowSession()
        let attention = makeAttention()
        // The error is newest and the finished oldest — severity must
        // still float the error to the top so it can't hide below an
        // older finished turn.
        let finishedOld = paneWithBadge(session, attention, .finished, at: 100)
        let needsMid = paneWithBadge(session, attention, .needsInput, at: 200)
        let errorNew = paneWithBadge(session, attention, .error, at: 300)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [errorNew, needsMid, finishedOld])
    }

    @Test func dismiss_dropsFinishedPaneFromList() {
        let session = WindowSession()
        let attention = makeAttention()
        let done = paneWithBadge(session, attention, .finished, at: 100)
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == done })

        attention.dismissRuntime(runtimeID(for: done))

        #expect(!attention.attentionEntries(in: session).contains { $0.paneID == done })
    }

    @Test func dismiss_doesNotAffectNeedsInput() {
        let session = WindowSession()
        let attention = makeAttention()
        let needs = paneWithBadge(session, attention, .needsInput, at: 100)

        attention.dismissRuntime(runtimeID(for: needs))

        // needsInput must persist until the underlying state resolves —
        // dismiss is a no-op against anything but `.finished`.
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == needs })
    }

    @Test func dismissedFinished_resurfacesOnNewerFinishedTurn() {
        let session = WindowSession()
        let attention = makeAttention()
        let paneID = paneWithBadge(session, attention, .finished, at: 100)

        attention.dismissRuntime(runtimeID(for: paneID))
        #expect(!attention.attentionEntries(in: session).contains { $0.paneID == paneID })

        // A later finished episode is a new event and must reappear
        // despite the earlier dismiss.
        setBadge(session, attention, paneID: paneID, .finished, at: 200)
        #expect(attention.attentionEntries(in: session).contains { $0.paneID == paneID })
    }

    @Test func focusMoved_marksFinishedAsViewed_butKeepsItInTheList() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .finished, at: 100)

        attention.focusMoved(to: pane, in: session)

        // Viewing is not completing: the row stays listed, but flagged
        // viewed so the UI can show its acknowledged style.
        let entry = attention.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry != nil)
        #expect(entry?.isViewed == true)
    }

    @Test func focusMoved_notifiesPaneHistorySync() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .running, at: 100)
        var focusedPane: UUID?
        attention.onPaneFocused = { focusedPane = $0 }

        attention.focusMoved(to: pane, in: session)

        #expect(focusedPane == pane)
    }

    @Test func focusMoved_doesNotMarkNeedsInputAsViewed() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .needsInput, at: 100)

        attention.focusMoved(to: pane, in: session)

        // Only finished turns carry the viewed state; needsInput stays at
        // full strength until it actually resolves.
        let entry = attention.attentionEntries(in: session).first { $0.paneID == pane }
        #expect(entry?.isViewed == false)
    }

    @Test func includeViewed_false_hidesViewedFinishedButKeepsNeedsInput() {
        let session = WindowSession()
        let attention = makeAttention()
        let seen = paneWithBadge(session, attention, .finished, at: 100)
        let unseen = paneWithBadge(session, attention, .finished, at: 200)
        let needs = paneWithBadge(session, attention, .needsInput, at: 300)
        attention.focusMoved(to: seen, in: session)

        attention.includeViewed = false
        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        // Viewed-finished hidden; unviewed-finished + needsInput kept.
        // needsInput / error are NEVER hidden by the toggle.
        #expect(ids == [unseen, needs])
    }

    @Test func hiddenViewedCount_reportsFilteredFinishedCount() {
        let session = WindowSession()
        let attention = makeAttention()
        let a = paneWithBadge(session, attention, .finished, at: 100)
        let b = paneWithBadge(session, attention, .finished, at: 200)
        _ = paneWithBadge(session, attention, .needsInput, at: 300)
        attention.focusMoved(to: a, in: session)
        attention.focusMoved(to: b, in: session)

        // Filter off → nothing hidden.
        #expect(attention.hiddenViewedCount(in: session) == 0)
        // Filter on → both viewed-finished are hidden, needsInput isn't
        // counted (it was never a viewed-finished candidate).
        attention.includeViewed = false
        #expect(attention.hiddenViewedCount(in: session) == 2)
    }

    @Test func includeViewed_true_isTheDefaultAndShowsEverything() {
        let session = WindowSession()
        let attention = makeAttention()
        let seen = paneWithBadge(session, attention, .finished, at: 100)
        let unseen = paneWithBadge(session, attention, .finished, at: 200)
        attention.focusMoved(to: seen, in: session)

        // Default value of includeViewed → both rows visible.
        #expect(attention.includeViewed)
        let ids = Set(attention.attentionEntries(in: session).map(\.paneID))
        #expect(ids == [seen, unseen])
    }

    @Test func sweepingWithFocus_keepsEveryFinishedTurnListed() {
        let session = WindowSession()
        let attention = makeAttention()
        let a = paneWithBadge(session, attention, .finished, at: 100)
        let b = paneWithBadge(session, attention, .finished, at: 200)

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
        let attention = makeAttention()
        // An error always tops the list — even if the only finished pane
        // in the list is unseen. Severity is the primary axis; viewed is
        // a tiebreaker within a tier.
        let unseenFinished = paneWithBadge(session, attention, .finished, at: 100)
        let err = paneWithBadge(session, attention, .error, at: 200)

        let order = attention.attentionEntries(in: session).map(\.paneID)
        #expect(order == [err, unseenFinished])
    }

    // MARK: - Aggregate AgentState (drives container / tab column badge icon)

    @Test func aggregateAgentState_runningOutranksViewedFinished() {
        // Once the user has handled the finished turn, the running
        // sibling should be what the aggregate badge advertises.
        let session = WindowSession()
        let attention = makeAttention()
        let done = paneWithBadge(session, attention, .finished, at: 100)
        _ = paneWithBadge(session, attention, .running, at: 200)
        attention.focusMoved(to: done, in: session)

        let summary = attention.aggregateAgentStateSummary(in: .loose, session: session)
        #expect(summary == AgentStateSummary(state: .running, isViewedFinished: false))
    }

    @Test func aggregateAgentState_runningStaysBelowUnviewedFinished() {
        // Unviewed `.finished` still outranks `.running` because it
        // represents a result the user has not handled yet.
        let session = WindowSession()
        let attention = makeAttention()
        _ = paneWithBadge(session, attention, .finished, at: 100)
        _ = paneWithBadge(session, attention, .running, at: 200)

        let summary = attention.aggregateAgentStateSummary(in: .loose, session: session)
        #expect(summary == AgentStateSummary(state: .finished, isViewedFinished: false))
    }

    @Test func aggregateAgentState_onlyViewedFinished_stillShowsCheck() {
        // No other state is present, so the finished state remains visible.
        let session = WindowSession()
        let attention = makeAttention()
        let done = paneWithBadge(session, attention, .finished, at: 100)
        attention.focusMoved(to: done, in: session)

        let summary = attention.aggregateAgentStateSummary(in: .loose, session: session)
        #expect(summary == AgentStateSummary(state: .finished, isViewedFinished: true))
    }

    @Test func aggregateAgentState_errorBeatsViewedFinishedAndRunning() {
        // Severity still wins above the running/viewed-finished
        // tiebreaker — an error must surface no matter what else sits
        // in the container.
        let session = WindowSession()
        let attention = makeAttention()
        let done = paneWithBadge(session, attention, .finished, at: 100)
        _ = paneWithBadge(session, attention, .running, at: 200)
        _ = paneWithBadge(session, attention, .error, at: 300)
        attention.focusMoved(to: done, in: session)

        let summary = attention.aggregateAgentStateSummary(in: .loose, session: session)
        #expect(summary == AgentStateSummary(state: .error, isViewedFinished: false))
    }

    @Test func viewedFinishedPresentation_usesAcknowledgedCheck() {
        #expect(AgentState.finished.iconName(isViewedFinished: false) == "checkmark.circle.fill")
        #expect(AgentState.finished.iconName(isViewedFinished: true) == "checkmark.circle")
        #expect(AgentState.error.iconName(isViewedFinished: true) == "exclamationmark.circle.fill")
    }

    // MARK: - ⌘J cursor honours the includeViewed filter

    @Test func focusingFinishedTurnWithBaseOpensReviewWhenEnabled() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let presentation = ReviewPresentation()
        let registry = NoopSurfaceRegistry()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let tree = String(repeating: "a", count: 40)
        let root = "/tmp/turn-review"
        setBadge(session, attention, paneID: paneID, .finished, at: 100, turnBaseTree: tree, turnRoot: root)
        attention.isTurnReviewEnabled = { true }
        attention.onFinishedTurnFocused = { paneID, tree, root in
            presentation.open(
                URL(fileURLWithPath: root),
                originPaneID: paneID,
                initialScope: .turn(baseTree: tree, paneID: paneID),
                transientOwnerPaneID: paneID
            )
        }

        attention.focusAttention(
            in: session, registry: registry,
            tabID: tab.id, paneID: paneID, runtimeID: runtimeID(for: paneID)
        )

        #expect(presentation.directory == URL(fileURLWithPath: root))
        #expect(presentation.requestedScope == .turn(baseTree: tree, paneID: paneID))
        #expect(presentation.transientOwnerPaneID == paneID)
    }

    @Test func focusingFinishedTurnLeavesReviewAloneWhenDisabled() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let presentation = ReviewPresentation()
        let registry = NoopSurfaceRegistry()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        setBadge(
            session, attention, paneID: paneID, .finished, at: 100,
            turnBaseTree: String(repeating: "a", count: 40), turnRoot: "/tmp/turn-review"
        )
        attention.isTurnReviewEnabled = { false }
        attention.onFinishedTurnFocused = { paneID, tree, root in
            presentation.open(
                URL(fileURLWithPath: root),
                originPaneID: paneID,
                initialScope: .turn(baseTree: tree, paneID: paneID)
            )
        }

        attention.focusAttention(
            in: session, registry: registry,
            tabID: tab.id, paneID: paneID, runtimeID: runtimeID(for: paneID)
        )

        #expect(!presentation.isPresented)
    }

    @Test func focusingNeedsInputNeverOpensTurnReview() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let presentation = ReviewPresentation()
        let registry = NoopSurfaceRegistry()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        setBadge(
            session, attention, paneID: paneID, .needsInput, at: 100,
            turnBaseTree: String(repeating: "a", count: 40), turnRoot: "/tmp/turn-review"
        )
        attention.isTurnReviewEnabled = { true }
        attention.onFinishedTurnFocused = { paneID, tree, root in
            presentation.open(
                URL(fileURLWithPath: root),
                originPaneID: paneID,
                initialScope: .turn(baseTree: tree, paneID: paneID)
            )
        }

        attention.focusAttention(
            in: session, registry: registry,
            tabID: tab.id, paneID: paneID, runtimeID: runtimeID(for: paneID)
        )

        #expect(!presentation.isPresented)
    }

    @Test func jumpToAttention_includeViewedFalse_skipsViewedFinished() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let registry = NoopSurfaceRegistry()
        // Three finished panes; mark the middle one viewed and hide
        // viewed-finished. The cursor must walk only the two visible
        // unviewed panes, not stop on the hidden one.
        let a = paneWithBadge(session, attention, .finished, at: 100)
        let b = paneWithBadge(session, attention, .finished, at: 200)
        let c = paneWithBadge(session, attention, .finished, at: 300)
        attention.focusMoved(to: b, in: session)
        attention.includeViewed = false

        // Park focus on `a`'s runtime so the cursor has a known starting
        // point — the cursor tracks the selected runtime, not just the pane.
        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)
        attention.selectedRuntimeID = runtimeID(for: a)

        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)

        // Forward again wraps inside the visible subset back to `a` —
        // the hidden `b` is skipped on the wrap as well.
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == a)
    }

    @Test func jumpToAttention_includeViewedTrue_walksEveryWaitingPane() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let registry = NoopSurfaceRegistry()
        let a = paneWithBadge(session, attention, .finished, at: 100)
        let b = paneWithBadge(session, attention, .finished, at: 200)
        let c = paneWithBadge(session, attention, .finished, at: 300)
        // `b` is viewed but the filter is on — viewed rows stay
        // reachable so the cursor behavior matches what the list shows.
        attention.focusMoved(to: b, in: session)

        let tabA = try #require(session.tabs.first { $0.splitTree.allLeafIDs().contains(a) })
        session.setActiveTab(tabA.id)
        attention.selectedRuntimeID = runtimeID(for: a)

        // List order is unviewed-first within the finished tier (a, c, b).
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == c)
        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTab?.splitTree.focusedLeafID == b)
    }

    // MARK: - Viewed-finished retention

    @Test func runtimeViewedFinished_pastRetentionDropsAndNewEpisodeReturns() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let tab = session.openTab(container: .loose)
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        attention.replaceRuntimes([
            runtime(.finished, paneID: paneID, revision: 100, episode: "100")
        ], kind: .codex)
        attention.markVisibleRuntimesViewed(paneID: paneID)

        attention.now = {
            Date(timeIntervalSince1970: 100 + AttentionState.viewedFinishedRetention + 60)
        }
        #expect(attention.attentionEntries(in: session).isEmpty)

        let newRevision = Int(100 + AttentionState.viewedFinishedRetention + 30)
        attention.replaceRuntimes([
            runtime(.finished, paneID: paneID, revision: newRevision, episode: "new")
        ], kind: .codex)
        #expect(attention.attentionEntries(in: session).map(\.paneID) == [paneID])
    }

    @Test func viewedFinished_pastRetention_dropsOffListAndAggregate() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        attention.focusMoved(to: pane, in: session)
        let tab = try #require(session.tab(containing: pane))

        // Just inside the ceiling: still listed with an acknowledged
        // check on the tab.
        attention.now = { Date(timeIntervalSince1970: 100 + AttentionState.viewedFinishedRetention - 60) }
        #expect(attention.attentionEntries(in: session).map(\.paneID) == [pane])
        #expect(attention.aggregateAgentStateSummary(in: tab)?.state == .finished)

        // Past the ceiling: gone from the list, the ⌘J cursor, and the
        // tab / container aggregate — same as pressing ×.
        attention.now = { Date(timeIntervalSince1970: 100 + AttentionState.viewedFinishedRetention + 60) }
        #expect(attention.attentionEntries(in: session).isEmpty)
        #expect(attention.aggregateAgentStateSummary(in: tab) == nil)
        #expect(attention.hiddenViewedCount(in: session) == 0)
    }

    @Test func unviewedFinished_pastRetention_staysListed() {
        let session = WindowSession()
        let attention = makeAttention()
        // Never focused, so never viewed — age alone must not hide a
        // result the user has not looked at yet.
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        attention.now = { Date(timeIntervalSince1970: 100 + AttentionState.viewedFinishedRetention * 10) }
        #expect(attention.attentionEntries(in: session).map(\.paneID) == [pane])
    }

    @Test func needsInput_neverAgesOut() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .needsInput, at: 100)
        attention.focusMoved(to: pane, in: session)
        attention.now = { Date(timeIntervalSince1970: 100 + AttentionState.viewedFinishedRetention * 10) }
        #expect(attention.attentionEntries(in: session).map(\.paneID) == [pane])
    }

    @Test func viewedFinished_agedOut_resurfacesOnNewerTurn() {
        let session = WindowSession()
        let attention = makeAttention()
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        attention.focusMoved(to: pane, in: session)
        let farFuture = 100 + AttentionState.viewedFinishedRetention * 2
        attention.now = { Date(timeIntervalSince1970: farFuture) }
        #expect(attention.attentionEntries(in: session).isEmpty)

        // A new finished episode carries a newer stamp, so the retention
        // rule (keyed to the viewed episode) no longer applies.
        setBadge(session, attention, paneID: pane, .finished, at: farFuture - 30)
        let entries = attention.attentionEntries(in: session)
        #expect(entries.map(\.paneID) == [pane])
        #expect(entries.first?.isViewed == false)
    }

    @Test func jumpToAttention_filterHidesEveryRow_isNoOp() throws {
        let session = WindowSession()
        let attention = makeAttention()
        let registry = NoopSurfaceRegistry()
        // Only one waiting pane and it's already viewed. With the filter
        // off the visible list is empty → ⌘J has nowhere to go and must
        // leave focus untouched rather than stepping into hidden rows.
        let pane = paneWithBadge(session, attention, .finished, at: 100)
        attention.focusMoved(to: pane, in: session)
        attention.includeViewed = false

        let other = session.openTab(container: .loose)
        let otherPane = try #require(other.splitTree.allLeafIDs().first)
        session.setActiveTab(other.id)

        attention.jumpToAttention(in: session, registry: registry, forward: true)
        #expect(session.activeTabID == other.id)
        #expect(session.activeTab?.splitTree.focusedLeafID == otherPane)
    }

    /// A run tmux keeps with no tab showing it is offered for reopening; a
    /// run whose tmux is gone, or whose agent ended its session, is not. The
    /// rules clear a badge's tmux flag once its endpoint is gone, and a
    /// session end leaves the badge with no state, so the two runs a record
    /// from an earlier server run on the same socket can stand for are both
    /// left out.
    @Test func detachedAgentRuns_listOnlyRunsTmuxStillKeeps() {
        let session = WindowSession()
        let attention = makeAttention()
        let endpoint = TmuxRuntimeEndpoint(socketPath: "/tmp/s", serverPID: "2", serverStartedAt: "20", paneID: "%0")
        func runtime(_ state: AgentState, isTmuxHosted: Bool) -> AgentRuntimePresentation {
            var badge = badge(state, at: 1)
            badge.isTmuxHosted = isTmuxHosted
            let leaf = UUID()
            return AgentRuntimePresentation(
                kind: .claude,
                runID: leaf.uuidString,
                revision: 1,
                badge: badge,
                paneIDs: [],
                tmuxLocations: [:],
                stateEpisodeToken: "1",
                attachmentResolution: .detached,
                tmuxRun: AgentTmuxRun(kind: .claude, endpoint: endpoint, leafID: leaf)
            )
        }
        let kept = runtime(.idle, isTmuxHosted: true)
        attention.replaceRuntimes([
            kept,
            runtime(.running, isTmuxHosted: false),
            runtime(.unknown, isTmuxHosted: true)
        ], kind: .claude)

        #expect(attention.detachedAgentRuns(in: session).map(\.id) == [kept.id])
    }
}

/// What the Waiting region says, in both languages. Here rather than in a
/// file of its own because these strings only make sense beside the rows
/// this suite already covers.
@Suite("Waiting region text")
struct WaitingRegionTextTests {
    private func resolved(_ resource: LocalizedStringResource, in identifier: String) -> String {
        var resource = resource
        resource.locale = Locale(identifier: identifier)
        return String(localized: resource)
    }

    /// The subheading over the agents with no tab. English in both locales,
    /// like the "Waiting" header it sits under.
    @Test func detachedHeader_readsTheSameInEveryLocale() {
        #expect(resolved("Detached", in: "en") == "Detached")
        #expect(resolved("Detached", in: "ja") == "Detached")
    }

    /// The row's own text carries the agent and its prompt; the hint says
    /// what activating it does, which is all the label used to say.
    @Test func detachedRow_textsResolveInJapanese() {
        #expect(resolved("Opens a tab showing this agent", in: "ja") == "このエージェントを表示するタブを開きます")
        #expect(resolved("Running in tmux without a tab", in: "ja") == "tmux で実行中（タブなし）")
    }

    /// What is refused in a mirror tab is the review surface, not one of its
    /// scopes.
    @Test func reviewRefusal_namesTheSurface() {
        #expect(resolved("Review can't open over a tmux tab yet", in: "en") == "Review can't open over a tmux tab yet")
        #expect(resolved("Review can't open over a tmux tab yet", in: "ja") == "tmux のタブでは、まだレビューを開けません")
    }

    @Test func detachedRunThatCannotBeReopened_saysItStopped() {
        #expect(
            resolved("That agent is no longer running in tmux", in: "ja")
                == "そのエージェントは tmux で実行されなくなりました"
        )
    }
}
