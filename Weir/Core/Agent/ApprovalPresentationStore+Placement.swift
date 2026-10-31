// ApprovalPresentationStore+Placement.swift
// Weir — where each request shows (its run, that run's panes, the wait that is its own) and when its turn is over.

import Foundation

extension ApprovalPresentationStore {
    /// Whether the wait `runtimeID` shows now is a request whose banner
    /// still stands (`ApprovalRequestState.keepsBanner`): the request's
    /// own banner speaks for it, so the wait posts none. The same test the
    /// attention list makes (`AttentionQueueReducer`): the run the request
    /// came from, and the wait episode it noted, or the first wait while
    /// none is noted. A request that timed out or was settled has had its
    /// banner taken back, and a later wait or another run's is announced
    /// as itself.
    func isWaitOfRequest(runtimeID: String, episodeToken: String, in session: WorkspaceSession) -> Bool {
        ledger.entries.values.contains { entry in
            guard entry.state.keepsBanner, run(for: entry.presentation, in: session)?.id == runtimeID else {
                return false
            }
            return entry.waitEpisodeToken.map { $0 == episodeToken } ?? true
        }
    }

    /// The tab and pane of every pane that runs the request's agent session:
    /// more than one when a tmux session is attached in several panes. Empty
    /// when the request names neither its run nor a session, so nothing can
    /// say where it would show, and once the run that asked has gone.
    ///
    /// The run that asked says where it is attached now: for a tmux run, the
    /// panes its tmux pane is open in, which need not include the pane it
    /// started in, and none while it is detached or before the first tmux
    /// probe. A run bound to the request speaks for it even then: a tmux run
    /// writes no session hint (`lifecycle.rs`), so a hint for its
    /// conversation belongs to another run of it, or is left from an earlier
    /// one. The hints stand in only before any run is known: the named run
    /// is not listed yet, or the request names none and no run reports its
    /// session yet, between the agent's start and its first hook.
    func panes(for approval: ApprovalPresentation, in session: WorkspaceSession) -> [(tabID: UUID, paneID: UUID)] {
        let run: AgentRuntimePresentation?
        switch binding(of: approval) {
        case .gone:
            return []
        case let .run(bound):
            return Self.placed(bound, in: session)
        case let .candidates(bound):
            return Self.likeliest(bound).map { Self.placed($0, in: session) } ?? []
        case .awaited:
            run = nil
        case .unbound:
            run = runForSession(of: approval)
        }
        if let run, !run.paneIDs.isEmpty {
            return Self.placed(run, in: session)
        }
        guard let sessionID = approval.sessionID else { return [] }
        return hintedPanes(for: approval, sessionID: sessionID, in: session)
    }

    /// The panes `run` is attached to, in the session's tab order, so the
    /// first pane is stable.
    private static func placed(
        _ run: AgentRuntimePresentation,
        in session: WorkspaceSession
    ) -> [(tabID: UUID, paneID: UUID)] {
        session.tabs.flatMap { tab in
            tab.splitTree.allLeafIDs().filter(run.paneIDs.contains).map { (tab.id, $0) }
        }
    }

    private func hintedPanes(
        for approval: ApprovalPresentation,
        sessionID: String,
        in session: WorkspaceSession
    ) -> [(tabID: UUID, paneID: UUID)] {
        session.tabs.flatMap { tab in
            (tab.agentSessions[approval.provider] ?? [:])
                .filter { $0.value.sessionId == sessionID }
                .map { (tab.id, $0.key) }
        }
    }

    /// Which run a request belongs to (`binding(of:)`).
    enum RunBinding {
        /// The run that asked: the one the request names
        /// (`ApprovalPresentation.agentRunID`), or, for a request that names
        /// none, the one run that could have asked it.
        case run(AgentRuntimePresentation)
        /// The runs that could have asked a request that names none, while
        /// more than one could (`ApprovalLedger.Entry.runtimeIDs`).
        case candidates([AgentRuntimePresentation])
        /// The run the request names has not been listed yet. Once the
        /// request has left the pending list and the broker has said how it
        /// ended, it never will be for this request: its helper is gone, and
        /// a run that is listed while the request is pending is bound to it.
        /// The ledger lets it go then (`endFinishedEpisodes`).
        case awaited
        /// The run that asked, or every run that could have, has gone.
        case gone
        /// The request names no run, and none of its conversation was in a
        /// turn when we looked.
        case unbound
    }

    /// The run a request belongs to. A request names the run that asked it
    /// (`ApprovalPresentation.agentRunID`, from the helper the run's hook
    /// started), and only that run speaks for it: a conversation resumed in
    /// a second run keeps its session ID, so the session alone cannot tell
    /// the two apart. A request that names no run (from an agent Weir did
    /// not start) is bound to the runs that could have asked it
    /// (`bindRequestsToRuns(in:)`).
    func binding(of approval: ApprovalPresentation) -> RunBinding {
        let runs = runtimes()
        let bound = ledger.entry(for: approval)?.runtimeIDs
        if let named = Self.askingRuntimeID(of: approval) {
            if let run = runs.first(where: { $0.id == named }) {
                return .run(run)
            }
            return bound == nil ? .awaited : .gone
        }
        guard let bound else { return .unbound }
        let listed = runs.filter { bound.contains($0.id) }
        if listed.count > 1 {
            return .candidates(listed)
        }
        return listed.first.map(RunBinding.run) ?? .gone
    }

    /// The runtime ID of the run the request names, if it names one.
    static func askingRuntimeID(of approval: ApprovalPresentation) -> String? {
        approval.agentRunID.map { AgentRuntimePresentation.id(kind: approval.provider, runID: $0.uuidString) }
    }

    /// The run the request came from (`binding(of:)`): the one it names, the
    /// likeliest of the runs that could have asked while more than one
    /// could, and `nil` while the named run is not listed yet or once the run
    /// that asked has gone. Before any run is bound to a request that names
    /// none, the one whose hooks reported the request's session; before the
    /// run's record carries the session, the run in the hinted pane that has
    /// no session yet, but only when that pane has one such run of the
    /// provider; with two (a tmux window split between two agents) guessing
    /// would bind the request to the wrong one. `nil` when no run is known.
    func run(for approval: ApprovalPresentation, in session: WorkspaceSession) -> AgentRuntimePresentation? {
        switch binding(of: approval) {
        case let .run(run): run
        case let .candidates(runs): Self.likeliest(runs)
        case .awaited, .gone: nil
        case .unbound: runForSession(of: approval) ?? unnamedRun(for: approval, in: session)
        }
    }

    /// Notes the run each request belongs to (`ApprovalLedger.Entry.runtimeIDs`),
    /// once. A request that names its run is noted once that run is listed,
    /// so the run going away later reads as gone rather than not listed yet.
    ///
    /// A request that names no run is bound to the runs that could have
    /// asked it: the runs of its conversation that are in a turn and started
    /// no later than we first saw the request, since only a run in a turn
    /// asks for anything and a run started after the request did not ask it;
    /// or, before any run's record carries the session, the one unnamed run
    /// in its hinted pane while that run is in a turn. One with no such run
    /// stays unbound and is tried again on the next pass: the projection can
    /// reach us after the request does, and a run's previous turn is no
    /// evidence about this one. Run before anything reads where a request
    /// belongs or whether its turn is over. Once bound, the run's badge at
    /// that moment counts as a sighting of the turn (`noteTurnsUnderWay`).
    func bindRequestsToRuns(in session: WorkspaceSession) {
        let runs = runtimes()
        for entry in ledger.entries.values where entry.runtimeIDs == nil {
            let approval = entry.presentation
            if let named = Self.askingRuntimeID(of: approval) {
                if runs.contains(where: { $0.id == named }) {
                    ledger.bindRuns(id: approval.id, runtimeIDs: [named])
                }
                continue
            }
            let ofSession = sessionRuns(of: approval)
            let candidates = ofSession.isEmpty ? unnamedRun(for: approval, in: session).map { [$0] } ?? [] : ofSession
            // `sessionStartedAt` is cut to whole seconds, which only moves it
            // earlier: a run started in the second we saw the request stays.
            let asking = candidates.filter {
                $0.badge.state.isMidTurn && ($0.badge.sessionStartedAt ?? .distantPast) <= entry.firstSeenAt
            }
            ledger.bindRuns(id: approval.id, runtimeIDs: Set(asking.map(\.id)))
        }
        noteTurnsUnderWay(in: session)
    }

    /// Notes each pending request whose run shows its turn under way now
    /// (`TurnStanding.showsTurnUnderWay`), as the release does on each pass.
    /// Read when a request arrives as well as on a projection pass: the run
    /// usually wrote `running` before it asked, and a pass may not come again
    /// until its turn has ended, which the guard on a turn's end would
    /// otherwise not count.
    func noteTurnsUnderWay(in session: WorkspaceSession) {
        for approval in pending where !observedActiveTurnIDs.contains(approval.id) {
            if turnStanding(for: approval, in: session)?.showsTurnUnderWay(since: firstSeenAt(for: approval)) == true {
                noteTurnSeen(approval)
            }
        }
    }

    /// The runs that reported the request's session.
    private func sessionRuns(of approval: ApprovalPresentation) -> [AgentRuntimePresentation] {
        guard let sessionID = approval.sessionID else { return [] }
        return runtimes().filter { $0.kind == approval.provider && $0.sessionID == sessionID }
    }

    /// The one run of the provider in a pane the request's session is hinted
    /// in that has no session yet, when that pane has exactly one.
    private func unnamedRun(for approval: ApprovalPresentation, in session: WorkspaceSession) -> AgentRuntimePresentation? {
        guard let sessionID = approval.sessionID else { return nil }
        let unnamed = runtimes().filter { $0.kind == approval.provider && $0.sessionID == nil }
        for (_, paneID) in hintedPanes(for: approval, sessionID: sessionID, in: session) {
            let inPane = unnamed.filter { $0.paneIDs.contains(paneID) }
            if inPane.count == 1 {
                return inPane.first
            }
        }
        return nil
    }

    /// The run that reported the request's session (`likeliest(_:)`).
    private func runForSession(of approval: ApprovalPresentation) -> AgentRuntimePresentation? {
        Self.likeliest(sessionRuns(of: approval))
    }

    /// The run of `runs` most likely to have asked. A resumed conversation
    /// keeps its session id, so the run before the resume can still be
    /// listed beside the one after it. Only a run in a turn asks for
    /// anything, so that one comes first, then one shown somewhere, then one
    /// in a known state, then the one that started its session last.
    private static func likeliest(_ runs: [AgentRuntimePresentation]) -> AgentRuntimePresentation? {
        runs.max { lhs, rhs in
            if lhs.badge.state.isMidTurn != rhs.badge.state.isMidTurn {
                return !lhs.badge.state.isMidTurn
            }
            if lhs.paneIDs.isEmpty != rhs.paneIDs.isEmpty {
                return lhs.paneIDs.isEmpty
            }
            if (lhs.badge.state == .unknown) != (rhs.badge.state == .unknown) {
                return lhs.badge.state == .unknown
            }
            return (lhs.badge.sessionStartedAt ?? lhs.badge.updatedAt) < (rhs.badge.sessionStartedAt ?? rhs.badge.updatedAt)
        }
    }

    /// The panes of `panes(for:in:)` that show the request's agent now, for
    /// handing the request to the TUI (in tmux, a pane shows only the
    /// tmux pane active in its window). Read for the run that asked, because
    /// two runs of one tmux session reach the same pane and only one of them
    /// can be in front there. A pane the request's run is not known to be
    /// attached to (one only its session hint names) counts only when no run
    /// of any provider is behind another tmux pane there, since we cannot
    /// tell which of them asked. None counts while the run the request names
    /// is not listed yet, while more than one run could have asked, or once
    /// the run that asked has gone: what cannot be placed is held.
    func shownPanes(for approval: ApprovalPresentation, in session: WorkspaceSession) -> [UUID] {
        let run: AgentRuntimePresentation?
        switch binding(of: approval) {
        case let .run(bound): run = bound
        case .candidates, .awaited, .gone: return []
        case .unbound: run = self.run(for: approval, in: session)
        }
        let all = runtimes()
        return panes(for: approval, in: session).map(\.paneID).filter { pane in
            if let run, run.paneIDs.contains(pane) {
                return run.activeAttachmentPaneIDs.contains(pane)
            }
            return all.allSatisfy { $0.tmuxLocations[pane]?.isActive ?? true }
        }
    }

    /// Where the turn a request was asked in stands, as the run that asked
    /// it tells it.
    enum TurnStanding: Equatable {
        /// The badge of the request's run, or, before a run is known for a
        /// request that names none, of the pane it shows in.
        case known(AgentBadge)
        /// The badges of the runs that could have asked a request that names
        /// none, while more than one could (`ApprovalLedger.Entry.runtimeIDs`).
        case undecided([AgentBadge])
        /// The run the request names is not listed yet, so nothing says
        /// where its turn stands.
        case awaitingRun

        /// Whether the turn is over (`turnHasEnded`). While it is undecided
        /// which run asked, once every one of them has: each was in a turn
        /// when the request was bound to it, so an end each shows after that
        /// is the end of that turn or a later one, and the run that asked is
        /// among them.
        func hasEnded(since firstSeenAt: Date) -> Bool {
            switch self {
            case let .known(badge): ApprovalPresentationStore.turnHasEnded(badge, since: firstSeenAt)
            case let .undecided(badges): badges.allSatisfy { ApprovalPresentationStore.turnHasEnded($0, since: firstSeenAt) }
            case .awaitingRun: false
            }
        }

        /// Whether the request's turn was seen under way: in a turn, or
        /// overtaken by a later prompt. While undecided, always: every run
        /// that could have asked was in a turn when it was bound.
        func showsTurnUnderWay(since firstSeenAt: Date) -> Bool {
            switch self {
            case let .known(badge):
                badge.state.isMidTurn
                    || ApprovalPresentationStore.isOvertaken(badge, since: firstSeenAt)
            case .undecided: true
            case .awaitingRun: false
            }
        }

        /// Whether the request's run is in a turn. While it is undecided
        /// which run asked, whether any of them is: the one that asked is in
        /// a turn until none is. `nil` while the named run is not listed.
        var isMidTurn: Bool? {
            switch self {
            case let .known(badge): badge.state.isMidTurn
            case let .undecided(badges): badges.contains { $0.state.isMidTurn }
            case .awaitingRun: nil
            }
        }
    }

    /// Where the request's turn stands: its run's badge, or, before a run is
    /// known for a request that names none, the badge of the pane it shows
    /// in. `nil` when neither is known, and once the run that asked (or
    /// every run that could have) has gone. Read from the run, not the pane,
    /// because the pane may show another run, and a tmux run's pane may not
    /// be known yet while its prompt still waits (hold what cannot be
    /// placed). The release rules read the turn's state and when the run
    /// last took a prompt (`AgentBadge.runStartedAt`) from this one badge,
    /// so a known run's state is never read beside another run's prompt. A
    /// bound run is never stood in for by the pane, which may show another
    /// run of the same conversation. The pane's badge is a guess that can
    /// still mix them: a pane split between two runs of the provider shows
    /// only one of them.
    func turnStanding(for approval: ApprovalPresentation, in session: WorkspaceSession) -> TurnStanding? {
        switch binding(of: approval) {
        case let .run(run): return .known(run.badge)
        case let .candidates(runs): return .undecided(runs.map(\.badge))
        case .awaited: return .awaitingRun
        case .gone: return nil
        case .unbound: break
        }
        if let run = run(for: approval, in: session) {
            return .known(run.badge)
        }
        return paneLocation(for: approval, in: session)
            .flatMap { tabID, paneID in session.tab(tabID)?.agentBadges[approval.provider]?[paneID] }
            .map(TurnStanding.known)
    }

    /// Whether the turn a request first seen at `firstSeenAt` was asked in is
    /// over, as `badge` (`turnStanding(for:in:)`) tells it: the run reports the
    /// turn's end, or a later prompt has overtaken it. The one test both the
    /// release of a pending request and the end of a ledger entry make
    /// (`releaseStaleApprovals`).
    nonisolated static func turnHasEnded(_ badge: AgentBadge, since firstSeenAt: Date) -> Bool {
        turnIsOver(badge.state) || isOvertaken(badge, since: firstSeenAt)
    }

    /// Whether the run took a prompt after we first saw the request, so a
    /// later turn has started and the request's own turn is over. The
    /// approval side of the overtaken turn in the projection
    /// (`projection.rs`), which reads a turn whose run started a later one
    /// as ended. A TUI permission dialog takes the prompt's place while it
    /// is up, so a new prompt in the run means the dialog is gone, answered
    /// or interrupted; and a request raised after a prompt is first seen
    /// after it, so its own prompt never overtakes it.
    ///
    /// `runStartedAt` is the hook's wall clock cut to whole seconds, and
    /// `firstSeenAt` the app's on the same Mac. The cut only moves the
    /// prompt earlier, so the strict `>` can miss a prompt taken within the
    /// second we first saw the request (the turn's end still ends it then),
    /// and while the wall clock runs forward it never ends a request its own
    /// prompt started. A step back between the prompt and our first sight
    /// (an NTP correction, a clock set after wake) can: the request's own
    /// prompt then reads as later, and the request leaves early, a held one
    /// going to the TUI. We accept that; it is rare, and the TUI still asks.
    nonisolated static func isOvertaken(_ badge: AgentBadge, since firstSeenAt: Date) -> Bool {
        guard let started = badge.runStartedAt else { return false }
        return started > firstSeenAt
    }

    /// Whether the run reports its turn over. An ended session (`unknown`)
    /// counts: the agent was quit at its dialog, and no answer will come.
    /// A run whose record outlives it (one hosted in tmux, which gc leaves
    /// alone until the next launch) would otherwise keep a request left to
    /// its terminal listed for as long as Weir runs, under whatever
    /// conversation the person started next. `unknown` is also a run not
    /// yet heard from, but a turn's end counts only once the turn was seen
    /// under way (`showsTurnUnderWay`), and a run seen in a turn is never
    /// unheard from again.
    nonisolated static func turnIsOver(_ state: AgentState) -> Bool {
        switch state {
        case .finished, .error, .idle, .unknown: true
        case .running, .compacting, .needsInput: false
        }
    }

    /// Notes the wait each run is showing as a request's own, so the list
    /// and the notifications treat that wait as the request and a later
    /// wait as itself. A wait no request holds yet goes to the run's oldest
    /// listed request that has none: a run has one state, so two of its
    /// requests showing at once share one wait, and it belongs to the one
    /// that came first; a request that came after an earlier one was
    /// answered gets the wait that follows. Run once per pass, before the
    /// list is built.
    ///
    /// The wait ending is not taken as an answer: another tool can move the
    /// run on while the TUI still asks, so a request handed to the terminal
    /// leaves the list at the turn's end, or when a later prompt of its run
    /// overtakes that turn (`releaseStaleApprovals`).
    func noteWaitEpisodes(in session: WorkspaceSession) {
        bindRequestsToRuns(in: session)
        // Each request with the run it is bound to, oldest first.
        let bound = sortedEntries
            .sorted { firstSeenAt(for: $0.presentation) < firstSeenAt(for: $1.presentation) }
            .compactMap { entry in run(for: entry.presentation, in: session).map { (entry: entry, run: $0) } }
        var handled: Set<String> = []
        for (_, run) in bound where run.badge.state == .needsInput && handled.insert(run.id).inserted {
            let token = run.attentionEventToken
            let ofRun = bound.filter { $0.run.id == run.id }.map(\.entry)
            // A wait some request already holds stays that request's.
            guard !ofRun.contains(where: { $0.waitEpisodeToken == token }),
                  let oldest = ofRun.first(where: { !$0.state.hasLeftTheQueue && $0.waitEpisodeToken == nil })
            else { continue }
            ledger.noteWait(id: oldest.presentation.id, episodeToken: token)
        }
    }

    /// The ledger's requests as the attention rules read them, each with
    /// the time left the service last reported.
    var approvalFacts: [ApprovalFact] {
        sortedEntries.map(fact(for:))
    }

    var sortedEntries: [ApprovalLedger.Entry] {
        ledger.entries.values.sorted { $0.presentation.id < $1.presentation.id }
    }

    func fact(for entry: ApprovalLedger.Entry) -> ApprovalFact {
        let approval = entry.presentation
        return ApprovalFact(
            key: approval.key,
            provider: approval.provider,
            isQuestion: approval.isQuestion,
            supportsNativeAnswer: approval.supportsNativeAnswer,
            state: entry.state,
            deadline: serviceDeadlines[approval.id]
        )
    }

    /// The ledger's requests with where each one shows, for the attention
    /// list, each bound to the run it came from (`run(for:in:)`). A request
    /// with no pane or no run is listed unplaced rather than dropped.
    func placedApprovals(in session: WorkspaceSession) -> [AttentionQueueReducer.PlacedApproval] {
        sortedEntries.map { entry in
            let approval = entry.presentation
            let subject: AttentionSubject = if let (tabID, paneID) = paneLocation(for: approval, in: session),
                                               let runtime = run(for: approval, in: session)
            {
                .runtime(
                    id: runtime.id,
                    provider: approval.provider,
                    paneID: paneID,
                    tabID: tabID,
                    projectID: session.tab(tabID)?.container.projectID
                )
            } else {
                .unplaced(provider: approval.provider)
            }
            return AttentionQueueReducer.PlacedApproval(
                fact: fact(for: entry),
                subject: subject,
                arrivedAt: firstSeenAt(for: approval),
                waitEpisodeToken: entry.waitEpisodeToken
            )
        }
    }

    func paneLocation(for approval: ApprovalPresentation, in session: WorkspaceSession) -> (UUID, UUID)? {
        panes(for: approval, in: session).first.map { ($0.tabID, $0.paneID) }
    }
}
