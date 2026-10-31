// AppState+AttentionQueue.swift
// Weir — keeps the attention list in step with the runtimes, the requests, and what the person sees.

import Foundation

extension AppState {
    /// Rebuilds the attention list whenever one of its sources changes.
    /// Here rather than in a store because the sources span Core (runtimes,
    /// the ledger) and Presentation (what the windows show).
    ///
    /// A run whose turns are recorded lists them (`UnreadTurnRules`): a
    /// turn that changed no files until its pane is in sight, one that did
    /// until the viewed line passes it, whatever the run does now. Any
    /// other finished run lists its episode until its viewed mark is set,
    /// when it ends in a pane the person can see (the projection decides
    /// that from `seenPanes`) or when its pane comes into sight afterwards
    /// (`markPanesComingIntoSight`).
    func startAttentionQueue() {
        // A session that did not come back from its file brings no pane
        // back either: the stops wait in their file for the launch that
        // restores it, rather than ending for want of panes.
        stopLedger.keepsStopsWithoutPanes = sessionLoadIssue != nil
        attentionQueue.performEffects = AttentionEffectPerformer(state: self).perform
        connectTurnReads()
        connectTurnRetention()
        connectAttentionNavigation()
        agentProjection.seenPanes = { [weak self] in
            self?.windowRegistry.attention.seenPanes ?? []
        }
        observeRepeatedly { [weak self] in
            _ = self?.windowRegistry.attention
        } onChange: { [weak self] in
            self?.markPanesComingIntoSight()
        }
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = windowRegistry.attention
            _ = attention.runtimesByKind
            _ = agentProjection.turnHistory.conversations
            _ = viewedLines.lines
        } onChange: { [weak self] in
            self?.applyTurnReads()
        }
        observeRepeatedly { [weak self] in
            guard let self else { return }
            _ = attention.runtimesByKind
            _ = agentProjection.turnHistory.conversations
            _ = turnReads.reads
            _ = viewedLines.lines
            // A restore takes its turns out of the list; its undo puts them back.
            _ = restores.journals
            _ = attention.viewedRuntimeTokens
            _ = approvalPresentation.ledger.entries
            _ = approvalPresentation.isRunning
            // A stop the person dismissed leaves the list at once.
            _ = stopLedger.ledger
            _ = session.tabs
            // A worktree found gone stops its row.
            _ = session.projects
            // Each window's tab, which `AttentionState.shownPane` reads.
            _ = session.shownTabIDs
            _ = sessionLaunches.launches
        } onChange: { [weak self] in
            self?.refreshAttentionQueue()
        }
        // A run whose process died shows for one pass only; its stop is
        // taken then (`onRunsExited`).
        agentProjection.onRunsExited = { [weak self] in
            self?.refreshAttentionQueue()
        }
        stopLedger.onResumeTimedOut = { [weak self] in
            // A launch resume that failed is a stop the list did not have;
            // one whose agent is in front ended a stop the list had.
            self?.refreshAttentionQueue()
            self?.refreshStopResumeOffers()
        }
        // What a resume's deadline reads: the agent in front of the
        // pane is the conversation back, whatever its run reported. The
        // agent itself, not a tmux client that may show a shell.
        stopLedger.isAgentInFront = PaneForegroundWiring.resumeDeadline(self)
        sessionLaunches.isAgentInFront = PaneForegroundWiring.launchFollow(self)
        paneAgentsInFront.read = PaneForegroundWiring.agentInFront(self)
        observeRepeatedly { [weak self] in
            guard let self else { return }
            // Nothing to follow, nothing to watch: the tabs and the
            // runtimes change often.
            guard sessionLaunches.isFollowing else { return }
            _ = session.tabs
            _ = attention.runtimesByKind
        } onChange: { [weak self] in
            guard let self else { return }
            sessionLaunches.follow(session: session, agentPanes: Set(attention.allRuntimes.flatMap(\.paneIDs)))
        }
        // A launch whose worktree was removed or hidden goes with it.
        observeRepeatedly { [weak self] in
            _ = self?.session.projects
        } onChange: { [weak self] in
            guard let self else { return }
            sessionLaunches.prune(keeping: session.visibleWorktreeIDs)
        }
        markPanesComingIntoSight()
        applyTurnReads()
        refreshAttentionQueue()
        // The projection's first pass ran while the app state was being
        // built, before this, so the runtimes are matched to their panes by
        // now. What the list held until here was already waiting at launch;
        // only what arrives from now on is announced.
        hasMatchedRuntimes = true
    }

    /// A pane in sight has been looked at: its finished turns are read,
    /// and its unread mark (a bell, a command's notification) goes, which
    /// also clears the Dock's dot for it. Switching tabs already cleared
    /// the mark with a flash; this covers coming back to Weir with the
    /// pane already in front, which no tab switch announces.
    private func markPanesComingIntoSight() {
        let seen = windowRegistry.attention.seenPanes
        for paneID in AttentionQueueStore.panesComingIntoSight(previous: seenPanesAtLastLook, current: seen) {
            attention.markViewed(paneID: paneID)
            session.clearUnread(paneID: paneID)
        }
        seenPanesAtLastLook = seen
    }

    /// Lets the badges and the notification history read a run as its turn
    /// records do, so they agree with the list.
    private func connectTurnReads() {
        attention.turnReadDecision = { [weak self] runtime in
            guard let self else { return nil }
            // The answer is kept until the history or the journals change, so
            // a pass of the list that asks this of every runtime works it out once.
            let restored = restoredTurnIDs()
            return TurnReadRules.isEpisodeRead(
                TurnReadRuntime(runtime),
                history: agentProjection.turnHistory.conversations,
                isRead: { [self] in isTurnRead($0, restored: restored) }
            )
        }
        attention.observeTurnReadSources = { [weak self] in
            guard let self else { return }
            _ = agentProjection.turnHistory.conversations
            _ = turnReads.reads
            _ = viewedLines.lines
            _ = restores.journals
        }
    }

    /// Records the turns read by having their pane in sight.
    private func applyTurnReads() {
        let runtimes = attention.allRuntimes.map(TurnReadRuntime.init)
        let history = agentProjection.turnHistory.conversations
        let read = TurnReadRules.turnsRead(
            inSight: windowRegistry.attention.seenPanes,
            runtimes: runtimes,
            history: history,
            seenWhilePending: &turnsSeenWhilePending
        )
        // Each mark keeps the end its turn was read at, so a turn whose end
        // is taken again reads anew (`TurnReadStore`).
        turnReads.markRead(history.values.joined().filter { read.contains($0.turnID) }.map(TurnReadStore.Mark.init))
    }

    /// A turn is read once its pane was in sight, for a turn that changed no
    /// files, or once the viewed line passes it, each as the turn ends now:
    /// a turn whose end was taken again since is read anew. A turn a restore
    /// took back has nothing left to read, so the list agrees with the
    /// changes panel.
    func isTurnRead(_ turn: TurnSummary) -> Bool {
        isTurnRead(turn, restored: restoredTurnIDs())
    }

    /// The same, with the restored turns already read once for a pass that
    /// asks of many turns.
    func isTurnRead(_ turn: TurnSummary, restored: Set<TurnID>) -> Bool {
        turnReads.isRead(turn) || viewedLines.isViewed(turn) || restored.contains(turn.turnID)
    }

    /// How a stop can be resumed from what its pane shows now. The bar and
    /// the button both read it.
    func stopResumeOffer(_ record: StopLedger.Record) -> DecisionBarContent.StopResume {
        let (job, hasDraft) = stopPaneJob(record)
        return StopResumeRules.offer(record: record, job: job, hasDraft: hasDraft)
    }

    /// Whether the stop's pane can start a new conversation now.
    func stopStartsNew(_ record: StopLedger.Record) -> Bool {
        let (job, hasDraft) = stopPaneJob(record)
        return StopResumeRules.startsNew(job: job, hasDraft: hasDraft)
    }

    private func stopPaneJob(_ record: StopLedger.Record) -> (AgentForeground.Job, Bool) {
        let terminal = registry.view(for: record.paneID)
        let job = AgentForeground.job(
            of: terminal?.foregroundGroupProcessNames ?? [],
            leaderArguments: terminal?.foregroundLeaderArguments,
            agent: record.provider
        )
        return (job, terminal?.hasUnsubmittedInput ?? false)
    }

    /// Reads each stop's resume again, and goes on doing so once a second
    /// while any stop is kept: the job in front of a pane changes with no
    /// event Weir hears of.
    func refreshStopResumeOffers() {
        stopLedger.refreshOffers(readStop)
        guard !stopLedger.ledger.records.isEmpty, stopOfferRefresh == nil else { return }
        stopOfferRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !stopLedger.ledger.records.isEmpty else { break }
                stopLedger.refreshOffers(readStop)
            }
            self?.stopOfferRefresh = nil
        }
    }

    private func readStop(
        _ record: StopLedger.Record
    ) -> (resume: DecisionBarContent.StopResume, newConversation: DecisionBarContent.ResumeBlocker?) {
        let (job, hasDraft) = stopPaneJob(record)
        return (
            StopResumeRules.offer(record: record, job: job, hasDraft: hasDraft),
            StopResumeRules.newConversationBlocker(job: job, hasDraft: hasDraft)
        )
    }

    /// The person moved on from a stop's conversation in its pane (its
    /// "Start New Conversation"). The pane's hint is what says the pane
    /// can resume that session: the launch rules restore a run whose resume
    /// never came back while the hint names it, and the restored pane types
    /// the resume the tab's candidates name. Left in place, a new
    /// conversation that never reported its own session (it failed to
    /// start, or was quit at once) would have the next launch resume the
    /// one the person ended and fail it into the stop again. So the hint
    /// goes, and the tab's candidate with it, which the next pass would
    /// drop as well; a hint or candidate a newer session took is kept.
    func forgetStoppedConversation(_ record: StopLedger.Record) {
        guard let sessionID = record.sessionID else { return }
        let kind = record.provider
        let paneID = record.paneID
        agentProjection.forgetSession(sessionID, of: kind, inPane: paneID)
        guard let tab = session.tab(containing: paneID), tab.agentSessions[kind]?[paneID]?.sessionId == sessionID else { return }
        session.update(tab.id) { tab in
            tab.agentSessions[kind]?[paneID] = nil
            tab.agentResumeCandidates[paneID]?.remove(kind)
            if tab.agentResumeCandidates[paneID]?.isEmpty == true {
                tab.agentResumeCandidates[paneID] = nil
            }
        }
    }

    /// Whether `agent` is the job in front of the pane's terminal.
    func isAgentInFront(_ agent: AgentKind, inPane paneID: UUID) -> Bool {
        guard let names = registry.view(for: paneID)?.foregroundGroupProcessNames else { return false }
        return AgentForeground.isAgent(agent, inFront: names)
    }

    /// Whether `agent` itself runs in front of the pane's terminal, which
    /// a resume's deadline takes for its conversation back
    /// (`AgentForeground.isAgentRunning`). Behind a tmux client, what its
    /// pane runs: Weir's own host of the agent, or the job the person's
    /// tmux server says its client's active pane has in front, asked off
    /// the main actor since tmux may take a while to answer.
    func isAgentRunningInFront(_ agent: AgentKind, inPane paneID: UUID) async -> Bool {
        guard let names = registry.view(for: paneID)?.foregroundGroupProcessNames else { return false }
        let tmuxPane = await TmuxPaneJob.inFront(of: names, inPane: paneID, presence: tmuxPresence)
        return AgentForeground.isAgentRunning(agent, inFront: names, tmuxPane: tmuxPane)
    }

    /// Which agent runs in front of the pane's terminal, for its badge
    /// before its run has a record (`AgentForeground.agentInFront`). Behind
    /// a tmux client, the job its pane runs, asked as a resume's deadline
    /// asks it (`TmuxPaneJob`).
    func agentInFrontReading(inPane paneID: UUID) async -> AgentInFrontReading {
        guard let names = registry.view(for: paneID)?.foregroundGroupProcessNames else { return .undetermined }
        let tmuxPane = await TmuxPaneJob.inFront(of: names, inPane: paneID, presence: tmuxPresence)
        return AgentForeground.agentInFront(names: names, tmuxPane: tmuxPane)
    }

    func refreshAttentionQueue() {
        // Which wait is a request's own, noted before the list is built
        // from the ledger.
        approvalPresentation.noteWaitEpisodes(in: session)
        let runtimes = attention.allRuntimes
        let restored = restoredTurnIDs()
        let unreadTurns = UnreadTurnRules.byRuntime(
            runtimes.map(UnreadTurnRules.Run.init),
            history: agentProjection.turnHistory.conversations,
            isRead: { [self] in isTurnRead($0, restored: restored) }
        )
        var input = AttentionQueueStore.makeInput(
            runtimes: runtimes,
            // Only a run no turn record stands for lists its episode.
            isRead: { [attention] in attention.isViewed($0) },
            unreadTurns: unreadTurns,
            approvals: approvalPresentation.placedApprovals(in: session),
            session: session,
            isApprovalServiceRunning: approvalPresentation.isRunning,
            launches: Array(sessionLaunches.launches.values)
        )
        // A stop outlives its run, until its conversation is back.
        let endedStops = stopLedger.update(
            runtimes: input.runtimes,
            paneExists: { [session] in session.tab(containing: $0) != nil },
            cwd: { [session] runtime in
                runtime.paneIDs.lazy.compactMap { session.tab(containing: $0)?.agentSessions[runtime.provider]?[$0]?.cwd }.first
            }
        )
        input.retainedStops = stopLedger.retained(besides: input.runtimes, session: session)
        input.dismissedStops = stopLedger.ledger.dismissed
        // A "Done" line ends as a turn starts in its pane or the agent
        // leaves. We end it here, where the runs come in, rather
        // than in the bar: a pane's bar is not drawn while review covers it
        // or after its agent left, and the line must not outlive the change
        // there. The runs are noted before the list is applied, so the bar
        // that sees the list change already knows which runs are in its pane.
        windowRegistry.noteRuns(runtimes.map(PaneRunLedger.Run.init), endedStops: endedStops)
        refreshStopResumeOffers()
        attentionQueue.apply(input, announces: hasMatchedRuntimes)
    }
}
