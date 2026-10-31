// AttentionQueueReducer.swift
// Weir — which items the attention list holds, worked out from runtimes and requests.

import Foundation

/// Turns what the runtimes and the approval ledger say into the attention
/// list, keeping the order items arrived in.
///
/// Each pass works out the items that should be listed now, removes the
/// ones that no longer should, updates the rest in place, and appends the
/// new ones. Nothing is re-sorted: the list is the order things happened.
enum AttentionQueueReducer {
    /// A request and where it shows.
    struct PlacedApproval: Equatable, Sendable {
        let fact: ApprovalFact
        let subject: AttentionSubject
        /// When Weir first saw the request pending.
        let arrivedAt: Date
        /// The episode of its run's wait that is this request seen from the
        /// hook; `nil` until the run has shown one.
        var waitEpisodeToken: String?
    }

    /// A new session that stopped before its agent started: its
    /// row is there, its agent is not.
    struct LaunchFailure: Equatable, Sendable {
        let projectID: UUID
        let worktreeRoot: URL
        let stage: NewSessionStage
        let logTail: String
        /// New for each failure (`SessionLaunch.Failure.token`).
        let token: String
        let failedAt: Date
    }

    /// A workspace whose worktree was deleted outside Weir: its
    /// row is there, its folder is not.
    struct MissingWorktree: Equatable, Sendable {
        let projectID: UUID
        let worktreeRoot: URL
        /// When the sync first found it gone, which the list counts from.
        let missingSince: Date
    }

    /// A stop its run no longer reports (`StopLedger.retained`), in the
    /// pane it happened in.
    struct RetainedStop: Equatable, Sendable {
        let itemID: AttentionItemID
        let runtimeID: String
        let provider: AgentKind
        let paneID: UUID
        let tabID: UUID?
        let projectID: UUID?
        let reason: StopReason
        let stoppedAt: Date
    }

    struct Input: Equatable, Sendable {
        var runtimes: [RuntimeFact] = []
        /// Every request the ledger keeps, settled ones included.
        var approvals: [PlacedApproval] = []
        /// Whether the approval service runs. A wait at the agent's prompt is
        /// then usually a request that has not reached Weir yet, or one
        /// just answered whose hook has not moved on; it is listed but not
        /// announced, so the person does not hear one request twice.
        var isApprovalServiceRunning = false
        var launchFailures: [LaunchFailure] = []
        var missingWorktrees: [MissingWorktree] = []
        var retainedStops: [RetainedStop] = []
        /// Stops the person dismissed while their run is still in error
        /// (`StopLedger.dismissed`).
        var dismissedStops: Set<AttentionItemID> = []
    }

    /// The next list, and the effects of what changed: a VoiceOver
    /// announcement for each new item that blocks on the person, and a
    /// banner for each new request.
    static func reduce(_ previous: AttentionQueue, input: Input) -> (AttentionQueue, [AttentionEffect]) {
        let wanted = wantedItems(input)
        let wantedIDs = Set(wanted.map(\.id))
        var queue = previous
        for item in previous.items where !wantedIDs.contains(item.id) {
            queue.remove(item.id)
        }
        var effects: [AttentionEffect] = []
        for item in wanted {
            if queue.insert(id: item.id, kind: item.kind, subject: item.subject, arrivedAt: item.arrivedAt) {
                if item.kind.isAnnounced(whileServiceRuns: input.isApprovalServiceRunning) {
                    effects.append(.announce(item.id))
                }
                // A request's banner comes from here, as it arrives, so it
                // carries the request and can open its card. The runtime's
                // own wait reaches Weir on another schedule (after the
                // hand-off for an approval, before the request for a
                // question), so it cannot say which request it is.
                if item.kind.isNotified {
                    effects.append(.notify(item.id))
                }
            } else if let current = queue.items.first(where: { $0.id == item.id }),
                      current.kind != item.kind || current.subject != item.subject
            {
                queue.update(id: item.id, kind: item.kind, subject: item.subject)
            }
        }
        queue.noteUsageLimitsLifted(by: input.runtimes)
        return (queue, effects)
    }

    private struct Wanted {
        let id: AttentionItemID
        let kind: AttentionItemKind
        let subject: AttentionSubject
        let arrivedAt: Date
    }

    /// The items that should be listed, oldest first, so new ones are
    /// appended in the order they happened even when several arrive in one
    /// pass. Ties fall back to the ID's text, so a pass is deterministic.
    private static func wantedItems(_ input: Input) -> [Wanted] {
        var wanted: [Wanted] = []
        for placed in input.approvals where !placed.fact.state.hasLeftTheQueue {
            let fact = placed.fact
            wanted.append(Wanted(
                id: fact.isQuestion ? .question(fact.key) : .approval(fact.key),
                kind: fact.isQuestion ? .question(fact) : .approval(fact),
                subject: placed.subject,
                arrivedAt: placed.arrivedAt
            ))
        }
        for runtime in input.runtimes {
            if let item = item(for: runtime, approvals: input.approvals), !input.dismissedStops.contains(item.id) {
                wanted.append(item)
            }
            wanted += unreadItems(for: runtime)
        }
        for stop in input.retainedStops {
            wanted.append(Wanted(
                id: stop.itemID,
                kind: .stop(stop.reason),
                subject: .runtime(
                    id: stop.runtimeID,
                    provider: stop.provider,
                    paneID: stop.paneID,
                    tabID: stop.tabID,
                    projectID: stop.projectID
                ),
                arrivedAt: stop.stoppedAt
            ))
        }
        for failure in input.launchFailures {
            wanted.append(Wanted(
                id: .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: failure.worktreeRoot), episodeToken: failure.token)),
                kind: .stop(.launchFailed(failure.stage, logTail: failure.logTail)),
                subject: .sessionRow(projectID: failure.projectID, worktreeRoot: failure.worktreeRoot),
                arrivedAt: failure.failedAt
            ))
        }
        // One stop for the workspace, not for each of its tabs: what it
        // offers (closing them all) is the workspace's.
        for missing in input.missingWorktrees {
            wanted.append(Wanted(
                id: .stop(EpisodeKey(origin: .sessionRow(worktreeRoot: missing.worktreeRoot), episodeToken: "worktreeMissing")),
                kind: .stop(.worktreeMissing),
                subject: .sessionRow(projectID: missing.projectID, worktreeRoot: missing.worktreeRoot),
                arrivedAt: missing.missingSince
            ))
        }
        return wanted.sorted { lhs, rhs in
            lhs.arrivedAt != rhs.arrivedAt
                ? lhs.arrivedAt < rhs.arrivedAt
                : String(describing: lhs.id) < String(describing: rhs.id)
        }
    }

    /// Whether the runtime's wait at its prompt is a request of its own,
    /// seen from the hook rather than the service: listing both would ask
    /// twice. It is when the wait is the episode the request noted, which
    /// still shows for a moment after an answer (the answered command has
    /// not started yet). Before the run has shown any wait, a listed
    /// request covers the first one, which is about to be its own. A later
    /// wait is a new one, and a request of another run in the same pane is
    /// not this run's.
    private static func isWaitForRequest(_ runtime: RuntimeFact, approvals: [PlacedApproval]) -> Bool {
        approvals.contains { placed in
            guard placed.subject.runtimeID == runtime.runtimeID else { return false }
            guard let token = placed.waitEpisodeToken else { return !placed.fact.state.hasLeftTheQueue }
            return token == runtime.episodeToken
        }
    }

    /// The item a runtime's state asks for, if any. A runtime with no pane
    /// is not shown anywhere yet, so it lists nothing.
    private static func item(for runtime: RuntimeFact, approvals: [PlacedApproval]) -> Wanted? {
        guard let subject = subject(of: runtime) else { return nil }
        let episode = EpisodeKey(origin: .runtime(runtime.runtimeID), episodeToken: runtime.episodeToken)
        switch runtime.state {
        case .needsInput:
            guard !isWaitForRequest(runtime, approvals: approvals) else { return nil }
            // Read once here, so every place that shows the wait names it
            // the same way: as its record says, else from its words.
            return Wanted(
                id: .prompt(episode),
                kind: .prompt(runtime.promptWait),
                subject: subject,
                arrivedAt: runtime.updatedAt
            )
        case .error:
            return Wanted(
                id: .stop(episode),
                kind: .stop(runtime.stopReason),
                subject: subject,
                arrivedAt: runtime.updatedAt
            )
        case .finished:
            // A run whose turns are recorded lists them instead
            // (`unreadItems`). Without them, the finished episode stands for
            // its turn, and what it changed is not known.
            guard runtime.unreadTurns == nil, !runtime.isEpisodeRead else { return nil }
            let turn = UnreadTurn(turnID: TurnID("\(runtime.runtimeID)#\(runtime.episodeToken)"), changes: .unknown)
            return Wanted(id: .unread(turn.turnID), kind: .unread(turn), subject: subject, arrivedAt: runtime.updatedAt)
        case .unknown, .running, .compacting, .idle:
            return nil
        }
    }

    /// The unread items of the run's turns, listed whatever the run does now:
    /// a turn that changed files waits for the person while the agent works
    /// on the next one.
    private static func unreadItems(for runtime: RuntimeFact) -> [Wanted] {
        guard let entries = runtime.unreadTurns, let subject = subject(of: runtime) else { return [] }
        return entries.map { entry in
            Wanted(
                id: .unread(entry.turn.turnID),
                kind: .unread(entry.turn),
                subject: subject,
                arrivedAt: entry.arrivedAt ?? runtime.updatedAt
            )
        }
    }

    /// Where a runtime's items show. A runtime with no pane is not shown
    /// anywhere yet, so it lists nothing.
    private static func subject(of runtime: RuntimeFact) -> AttentionSubject? {
        guard let paneID = runtime.paneIDs.first else { return nil }
        return .runtime(
            id: runtime.runtimeID,
            provider: runtime.provider,
            paneID: paneID,
            tabID: runtime.tabID,
            projectID: runtime.projectID
        )
    }
}

private extension AttentionItemKind {
    /// Whether a new item of this kind posts its own banner here. Stops and
    /// finished turns are announced by the runtime projection instead.
    var isNotified: Bool {
        switch self {
        case .approval, .question: true
        case .prompt, .stop, .unread: false
        }
    }

    /// Whether a new item of this kind is read out by VoiceOver. Only what
    /// blocks on the person: unread turns are frequent, and announcing each
    /// would interrupt the work they report on. A prompt is left to its
    /// request while the service runs (`Input.isApprovalServiceRunning`).
    func isAnnounced(whileServiceRuns isServiceRunning: Bool) -> Bool {
        switch self {
        case .approval, .question, .stop: true
        case .prompt: !isServiceRunning
        case .unread: false
        }
    }
}
