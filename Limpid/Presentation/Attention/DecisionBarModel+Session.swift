// DecisionBarModel+Session.swift
// Limpid — reads one pane's decision bar from the attention list, its agent, and the window.

import Foundation

extension DecisionBarModel {
    /// What decides the bar, read from the app's state.
    struct Sources {
        let session: WorkspaceSession
        let window: ProjectWindowState
        let queue: AttentionQueue
        let runtimes: [AgentRuntimePresentation]
        let approvals: ApprovalLedger
        /// The item ⌘J goes to next from this window, and the project the
        /// window counts as its own, as ⌘J reads them
        /// (`AttentionQueueStore.peekNext`). Only read while the pane's bar
        /// says "Done", which is the one line that names it.
        let next: (item: AttentionItem, windowProjectID: UUID?)?
        /// Every conversation's turns, for the receipt of the agent's
        /// latest turn while it rests.
        var history: [ConversationKey: [TurnSummary]] = [:]
        /// How a stop of the pane can be resumed (`StopResumeRules`).
        var stopResume: (AttentionItem) -> DecisionBarContent.StopResume = { _ in .unavailable }
        /// What a usage limit stop offers while its limit holds
        /// (`UsageLimitResetNotice`), at `now`.
        var resetNotice: (AttentionItem) -> UsageLimitResetNotice? = { _ in nil }
        /// The time the bar is worded at: a usage limit's reset is named
        /// only while it is ahead.
        var now = Date()
    }

    /// The bar of `paneID`, or `nil` for a pane with no agent: the bar is
    /// there only while an agent runs in the pane, so a shell's rows
    /// change once when an agent starts and once when it leaves. A stop
    /// keeps it after its agent exited, until the conversation is back.
    @MainActor
    init?(paneID: UUID, sources: Sources, locale: Locale) {
        let items = Self.items(in: paneID, queue: sources.queue, session: sources.session)
        guard let agent = Self.agent(in: paneID, runtimes: sources.runtimes, session: sources.session) ?? Self.stoppedAgent(in: items)
        else { return nil }
        let approvalActions = Dictionary(uniqueKeysWithValues: items.compactMap { item -> (ApprovalKey, PromptApproval.Action)? in
            guard case let .approval(fact) = item.kind,
                  let request = sources.approvals.entries[fact.key]?.presentation
            else { return nil }
            return (fact.key, ApprovalRequestText(request).action)
        })
        let content = DecisionBarContent.make(.init(
            items: items,
            selected: sources.window.decisionBarSelection[paneID],
            agent: agent,
            approvalActions: approvalActions,
            done: sources.window.decisionBarDone[paneID].map {
                DecisionBarContent.Done(result: $0, next: sources.next?.item.id)
            },
            lastTurn: Self.lastTurn(in: paneID, sources: sources),
            stopResumes: Dictionary(
                items.filter {
                    if case .stop = $0.kind {
                        true
                    } else {
                        false
                    }
                }.map { ($0.id, sources.stopResume($0)) },
                uniquingKeysWith: { first, _ in first }
            ),
            // The run the receipt at rest is read from (`runtime(in:runtimes:)`);
            // `make` says it beside an unread turn only when it is that run's.
            backgroundWork: Self.runtime(in: paneID, runtimes: sources.runtimes).flatMap { runtime in
                runtime.badge.backgroundWork.map { .init(runtimeID: runtime.id, work: $0) }
            }
        ))
        let shown = items.first { $0.id == content.itemID }
        self.init(content: content, resetNotice: shown.flatMap(sources.resetNotice), now: sources.now, locale: locale) { _ in
            Self.nextName(sources: sources, locale: locale)
        }
    }

    /// The pane's agent as its runtime last reported it, as the tab's badge
    /// has it before the runtime is matched to the pane, or as its terminal
    /// runs it in front before it has any record. The pane has
    /// a bar while this is not `nil`, or while a stop of its agent waits
    /// (`hasBar`), and ⌘⏎ is kept from the terminal there even while review
    /// hides the bar.
    @MainActor
    static func agent(
        in paneID: UUID,
        runtimes: [AgentRuntimePresentation],
        session: WorkspaceSession
    ) -> SessionRowFact.Agent? {
        if let runtime = runtime(in: paneID, runtimes: runtimes) {
            return .init(runtime: runtime)
        }
        guard let tab = session.tab(containing: paneID) else { return nil }
        if let kind = tab.agentKind(inPane: paneID), let badge = tab.agentBadges[kind]?[paneID], badge.state != .unknown {
            return .init(provider: kind, state: badge.state, detail: badge.detail, backgroundWork: badge.backgroundWork)
        }
        // Codex reports nothing before its first prompt, yet it is running:
        // without this its pane would have no bar beside a Claude pane's, and
        // its rows would shift when the bar arrived at that prompt. It waits
        // at that prompt until then, so the bar says it rests. A staged agent
        // has no bar yet: its command is not typed, and a shell is in front.
        guard let kind = tab.agentInFrontWithoutRecord(inPane: paneID), tab.agentsInFront[paneID]?.isStaged != true else { return nil }
        return .init(provider: kind, state: .idle, detail: nil)
    }

    /// Returns the run the pane's bar speaks for, of the runs in the pane:
    /// the first running a turn, else the first resting with work its turn
    /// left running, else the first (`SessionRowFact.leadAgentIndex`), as
    /// the pane's header picks it. We pick it once, so the bar's state and
    /// its last turn's receipt are the same run's: a finished run beside
    /// a running one in the pane does not put an old turn under the
    /// header's Running. A run that has reported goes before one that has not:
    /// one restored at launch stays placed in the pane after a new agent
    /// starts there, and would keep the bar at Unknown.
    static func runtime(in paneID: UUID, runtimes: [AgentRuntimePresentation]) -> AgentRuntimePresentation? {
        let placed = runtimes.filter { $0.paneIDs.contains(paneID) }
        let reported = placed.filter { $0.badge.state != .unknown }
        let inPane = reported.isEmpty ? placed : reported
        return SessionRowFact.leadAgentIndex(of: inPane.map(SessionRowFact.Agent.init(runtime:))).map { inPane[$0] }
    }

    /// The stop of a workspace whose worktree is gone, which its row lists
    /// and no pane names, in the bar of each of its agents' panes.
    /// A pane with no agent keeps no bar for it: the row and the list say
    /// it there.
    @MainActor
    private static func missingWorktreeStops(in paneID: UUID, queue: AttentionQueue, session: WorkspaceSession) -> [AttentionItem] {
        guard let tab = session.tab(containing: paneID),
              let root = session.rootDirectory(of: tab.container)
        else { return [] }
        return queue.items.filter { $0.kind == .stop(.worktreeMissing) && $0.subject.isSessionRow(at: root) }
    }

    /// What the bar of `paneID` can show: the items of the pane, and the stop
    /// of its worktree if that is gone.
    @MainActor
    static func items(in paneID: UUID, queue: AttentionQueue, session: WorkspaceSession) -> [AttentionItem] {
        queue.items(inPane: paneID) + missingWorktreeStops(in: paneID, queue: queue, session: session)
    }

    /// Whether the bar stays at full strength in a pane without focus, rather
    /// than fading with its terminal: something waits on the person, and its
    /// words are what they have to read, wherever the keyboard is.
    @MainActor
    static func staysOpaque(in paneID: UUID, queue: AttentionQueue, session: WorkspaceSession) -> Bool {
        PaneAttention.of(items(in: paneID, queue: queue, session: session)) != nil
    }

    /// The agent of a stop the pane keeps after its run is gone.
    static func stoppedAgent(in items: [AttentionItem]) -> SessionRowFact.Agent? {
        for item in items {
            if case .stop = item.kind, let provider = item.subject.provider {
                return .init(provider: provider, state: .error, detail: nil)
            }
        }
        return nil
    }

    /// Whether the pane has a bar: an agent runs there, or a stop of one
    /// waits. ⌘⏎ is kept from the terminal there.
    @MainActor
    static func hasBar(in paneID: UUID, runtimes: [AgentRuntimePresentation], session: WorkspaceSession, queue: AttentionQueue) -> Bool {
        agent(in: paneID, runtimes: runtimes, session: session) != nil || stoppedAgent(in: queue.items(inPane: paneID)) != nil
    }

    /// The receipt of the latest turn of the conversation the pane's agent
    /// (`runtime(in:runtimes:)`) is in.
    @MainActor
    private static func lastTurn(in paneID: UUID, sources: Sources) -> UnreadTurn? {
        guard let conversation = runtime(in: paneID, runtimes: sources.runtimes)?.conversation,
              let turn = UnreadTurnRules.latestPrompted(in: sources.history[conversation] ?? [])
        else { return nil }
        return UnreadTurnRules.receipt(of: turn)
    }

    /// The name of the item ⌘J goes to next. Another project's item names
    /// its project too, so the next step is not mistaken for one in this
    /// window.
    @MainActor
    private static func nextName(sources: Sources, locale: Locale) -> String? {
        guard let next = sources.next else { return nil }
        let names = NeedsAttentionListModel.names(of: next.item, in: sources.session, locale: locale)
        guard let place = names.place, next.item.subject.projectID != next.windowProjectID else { return names.title }
        return AgentStatusText.joined([names.title, place], locale: locale)
    }
}
