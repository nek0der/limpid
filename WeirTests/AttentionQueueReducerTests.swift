// AttentionQueueReducerTests.swift
// Weir — which items the attention list holds, and in what order they arrive.

import Foundation
import Testing
@testable import Weir

struct AttentionQueueReducerTests {
    private static let start = Date(timeIntervalSince1970: 1000)
    private static let paneA = UUID()
    private static let paneB = UUID()

    private static func runtime(
        _ id: String,
        _ state: AgentState,
        pane: UUID = paneA,
        at seconds: TimeInterval = 0,
        episode: String = "1",
        isRead: Bool = false,
        detail: String? = nil,
        provider: AgentKind = .claude
    ) -> RuntimeFact {
        RuntimeFact.test(
            id, state, provider: provider, pane: pane, tabID: UUID(), updatedAt: start.addingTimeInterval(seconds),
            episode: episode, isRead: isRead, detail: detail
        )
    }

    private static func request(
        _ state: ApprovalRequestState = .held,
        pane: UUID? = paneA,
        at seconds: TimeInterval = 0,
        isQuestion: Bool = false,
        provider: AgentKind = .claude,
        runtime: String = "a",
        waitEpisode: String? = nil
    ) -> AttentionQueueReducer.PlacedApproval {
        let fact = ApprovalFact(
            key: ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID()),
            provider: provider,
            isQuestion: isQuestion,
            supportsNativeAnswer: !(provider == .codex && isQuestion),
            state: state,
            deadline: nil
        )
        let subject: AttentionSubject = pane.map {
            .runtime(id: runtime, provider: provider, paneID: $0, tabID: nil, projectID: nil)
        } ?? .unplaced(provider: provider)
        return AttentionQueueReducer.PlacedApproval(
            fact: fact,
            subject: subject,
            arrivedAt: start.addingTimeInterval(seconds),
            waitEpisodeToken: waitEpisode
        )
    }

    private static func reduce(
        _ input: AttentionQueueReducer.Input,
        from queue: AttentionQueue = AttentionQueue()
    ) -> (queue: AttentionQueue, effects: [AttentionEffect]) {
        let (next, effects) = AttentionQueueReducer.reduce(queue, input: input)
        return (next, effects)
    }

    // MARK: - Requests

    @Test func aRequest_isListedAnnouncedAndNotified() {
        // Its banner comes from here, as it arrives, carrying the request.
        let held = Self.request()
        let result = Self.reduce(.init(approvals: [held]))

        let id = AttentionItemID.approval(held.fact.key)
        #expect(result.queue.items.map(\.id) == [id])
        #expect(result.effects == [.announce(id), .notify(id)])
    }

    @Test func aStopOrAnUnreadTurn_isNotNotifiedFromHere() {
        // The runtime projection posts those banners.
        let result = Self.reduce(.init(runtimes: [
            Self.runtime("a", .error),
            Self.runtime("b", .finished, pane: Self.paneB),
            Self.runtime("c", .needsInput, pane: UUID())
        ]))
        #expect(!result.effects.contains {
            if case .notify = $0 {
                true
            } else {
                false
            }
        })
    }

    @Test func questions_areTheirOwnKind_andACodexOneIsAnsweredInTheTerminal() {
        let claude = Self.request(isQuestion: true)
        let codex = Self.request(at: 1, isQuestion: true, provider: .codex)
        let queue = Self.reduce(.init(approvals: [claude, codex])).queue

        #expect(queue.items.map(\.id) == [.question(claude.fact.key), .question(codex.fact.key)])
        #expect(queue.items.map(\.canAnswerInWeir) == [true, false])
    }

    @Test(arguments: [
        ApprovalRequestState.handedToTerminal(since: SuspendingClock.now),
        .timedOut,
        .unknownResult,
        .sending(.allowOnce, since: SuspendingClock.now),
        .sendFailed(.deny, error: "offline")
    ])
    func aRequestStillOpenSomewhere_staysListed(_ state: ApprovalRequestState) {
        let first = Self.request()
        let listed = Self.reduce(.init(approvals: [first])).queue
        let moved = AttentionQueueReducer.PlacedApproval(
            fact: ApprovalFact(
                key: first.fact.key, provider: .claude, isQuestion: false,
                supportsNativeAnswer: true, state: state, deadline: nil
            ),
            subject: first.subject,
            arrivedAt: first.arrivedAt
        )

        let result = Self.reduce(.init(approvals: [moved]), from: listed)

        #expect(result.queue.items.count == 1)
        #expect(result.queue.items.first?.kind == .approval(moved.fact))
        #expect(result.effects.isEmpty, "a change of state is not news")
    }

    @Test(arguments: [ApprovalRequestState.answered(.allowOnce), .withdrawn])
    func aSettledRequest_leaves(_ state: ApprovalRequestState) {
        let first = Self.request()
        let listed = Self.reduce(.init(approvals: [first])).queue
        let settled = AttentionQueueReducer.PlacedApproval(
            fact: ApprovalFact(
                key: first.fact.key, provider: .claude, isQuestion: false,
                supportsNativeAnswer: true, state: state, deadline: nil
            ),
            subject: first.subject,
            arrivedAt: first.arrivedAt
        )

        #expect(Self.reduce(.init(approvals: [settled]), from: listed).queue.items.isEmpty)
    }

    @Test func anUnplacedRequest_isStillListed_andPlacingItIsNotNews() {
        let unplaced = Self.request(pane: nil)
        let first = Self.reduce(.init(approvals: [unplaced]))
        #expect(first.queue.items.count == 1)

        let placed = AttentionQueueReducer.PlacedApproval(
            fact: unplaced.fact,
            subject: .runtime(id: "r", provider: .claude, paneID: Self.paneA, tabID: nil, projectID: nil),
            arrivedAt: unplaced.arrivedAt
        )
        let second = Self.reduce(.init(approvals: [placed]), from: first.queue)
        #expect(second.queue.items.first?.subject.paneID == Self.paneA)
        #expect(second.effects.isEmpty)
    }

    // MARK: - Runtimes

    @Test func aWaitWithNoRequest_isAPromptAtTheTerminal() {
        let waiting = Self.runtime("a", .needsInput, detail: "Allow Bash?")
        let result = Self.reduce(.init(runtimes: [waiting]))

        let episode = EpisodeKey(origin: .runtime("a"), episodeToken: "1")
        #expect(result.queue.items.map(\.id) == [.prompt(episode)])
        #expect(result.queue.items.first?.kind == .prompt(.unclassified(detail: "Allow Bash?")))
        #expect(result.effects == [.announce(.prompt(episode))])
    }

    /// The reducer lists a wait under the kind its record says, and falls
    /// back to the wait's words (`PromptWait`) when the record names none.
    @Test func aWait_isListedUnderItsKind() {
        var question = Self.runtime("q", .needsInput, detail: "Read: which file first?")
        question.waitKind = .question
        var monitor = Self.runtime("m", .needsInput, pane: Self.paneB, detail: "Monitor")
        monitor.waitKind = .approval
        monitor.tool = "Monitor"
        let kinds = Self.reduce(.init(runtimes: [
            Self.runtime("a", .needsInput, detail: "Write: /repo/notes.txt"),
            question,
            monitor
        ])).queue.items.map(\.kind)

        #expect(kinds.contains(.prompt(.approval(PromptApproval(
            tool: "Write",
            action: .fileChange,
            subject: "notes.txt",
            detail: "Write: /repo/notes.txt"
        )))))
        #expect(kinds.contains(.prompt(.question(detail: "Read: which file first?"))))
        #expect(kinds.contains(.prompt(.approval(PromptApproval(tool: "Monitor", action: .other, subject: nil, detail: "Monitor")))))
    }

    @Test func theRunsWaitWhileItsRequestIsListed_isListedOnce() {
        // Before the run's wait was noted, the request covers its first one.
        let waiting = Self.runtime("a", .needsInput)
        let held = Self.request()
        let noted = Self.request(waitEpisode: "1")

        #expect(Self.reduce(.init(runtimes: [waiting], approvals: [held])).queue.items.map(\.id) == [.approval(held.fact.key)])
        #expect(Self.reduce(.init(runtimes: [waiting], approvals: [noted])).queue.items.map(\.id) == [.approval(noted.fact.key)])
    }

    @Test func aWaitAfterItsRequestWasAnswered_isNotListedAgain() {
        // The hook keeps the run waiting while the allowed command starts:
        // the same episode the request noted.
        let waiting = Self.runtime("a", .needsInput, at: 0, episode: "1")
        let answered = Self.request(.answered(.allowOnce), waitEpisode: "1")

        let result = Self.reduce(.init(runtimes: [waiting], approvals: [answered]))

        #expect(result.queue.items.isEmpty)
        #expect(result.effects.isEmpty)
    }

    @Test func anAnsweredRequestWithNoWaitOfItsOwn_coversNoWait() {
        // Answered on the card before the run ever waited: the wait that
        // comes later is not this request's.
        let later = Self.runtime("a", .needsInput, episode: "1")
        let answered = Self.request(.answered(.allowOnce))

        let queue = Self.reduce(.init(runtimes: [later], approvals: [answered])).queue

        #expect(queue.items.count == 1)
    }

    @Test func aNewWaitAfterTheAnswer_isListed() {
        // The same turn waits again at the prompt, in the same second, for
        // something that never reached the service: another episode.
        let next = Self.runtime("a", .needsInput, at: 0, episode: "2")
        let answered = Self.request(.answered(.allowOnce), waitEpisode: "1")

        let result = Self.reduce(.init(runtimes: [next], approvals: [answered]))

        let episode = EpisodeKey(origin: .runtime("a"), episodeToken: "2")
        #expect(result.queue.items.map(\.id) == [.prompt(episode)])
        #expect(result.effects == [.announce(.prompt(episode))])
    }

    @Test func anotherRuntimesWaitInTheSamePane_isListed() {
        // Two agents in one pane (a tmux session with two runs): the request
        // is the first one's, the wait the second one's.
        let other = Self.runtime("b", .needsInput)
        let held = Self.request(runtime: "a")

        let queue = Self.reduce(.init(runtimes: [other], approvals: [held])).queue

        let episode = EpisodeKey(origin: .runtime("b"), episodeToken: "1")
        #expect(queue.items.map(\.id) == [.approval(held.fact.key), .prompt(episode)])
    }

    @Test func aWaitWhileTheServiceRuns_isListedButNotAnnounced() {
        // Its request is usually on the way; announcing both would ask twice.
        let waiting = Self.runtime("a", .needsInput)
        let result = Self.reduce(.init(runtimes: [waiting], isApprovalServiceRunning: true))

        #expect(result.queue.items.count == 1)
        #expect(result.effects.isEmpty)

        let stop = Self.runtime("b", .error, pane: Self.paneB)
        let stopped = Self.reduce(.init(runtimes: [waiting, stop], isApprovalServiceRunning: true), from: result.queue)
        #expect(stopped.effects.count == 1, "a stop is still announced")
    }

    @Test func aStop_isListedUntilItsEpisodeEnds_andAnotherFailureIsNew() {
        let failed = Self.runtime("a", .error, detail: "Rate limited")
        let first = Self.reduce(.init(runtimes: [failed]))
        let stop = AttentionItemID.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1"))
        #expect(first.queue.items.map(\.id) == [stop])
        #expect(first.queue.items.first?.kind == .stop(.error("Rate limited")))
        #expect(first.effects == [.announce(stop)])

        let resumed = Self.reduce(.init(runtimes: [Self.runtime("a", .running, episode: "2")]), from: first.queue)
        #expect(resumed.queue.items.isEmpty)

        let again = Self.reduce(.init(runtimes: [Self.runtime("a", .error, episode: "3")]), from: resumed.queue)
        #expect(again.queue.items.map(\.id) == [.stop(EpisodeKey(origin: .runtime("a"), episodeToken: "3"))])
        // A stop with no message says so.
        #expect(again.queue.items.first?.kind == .stop(.error(nil)))
    }

    @Test func aFinishedTurn_isUnreadUntilRead_andNotAnnounced() {
        let finished = Self.runtime("a", .finished)
        let first = Self.reduce(.init(runtimes: [finished]))
        #expect(first.queue.items.count == 1)
        if case let .unread(turn)? = first.queue.items.first?.kind {
            #expect(turn.changes == .unknown)
        } else {
            Issue.record("expected an unread turn")
        }
        #expect(first.effects.isEmpty)

        let read = Self.reduce(.init(runtimes: [Self.runtime("a", .finished, isRead: true)]), from: first.queue)
        #expect(read.queue.items.isEmpty)
    }

    // MARK: - Recorded turns

    private static func turns(_ entries: [UnreadTurn], for runtime: RuntimeFact) -> RuntimeFact {
        var runtime = runtime
        runtime.unreadTurns = entries.map { UnreadTurnEntry(turn: $0, arrivedAt: nil) }
        return runtime
    }

    private static func recorded(_ first: String, _ numbers: ClosedRange<Int>, _ changes: ChangeSummary) -> UnreadTurn {
        UnreadTurn(turnID: TurnID(first), numbers: numbers, changes: changes, conversation: TurnSummaryFixture.conversation)
    }

    @Test func recordedTurns_listChangedUnchangedAndUntaken_whateverTheRunDoesNow() {
        let turns = [
            Self.recorded("T6", 6...7, .changed(files: 2, added: 94, removed: 2)),
            Self.recorded("T3", 3...3, .unchanged),
            Self.recorded("T5", 5...5, .unavailable(reason: "notGit"))
        ]

        // Working on the next turn, the earlier ones still wait.
        let listed = Self.reduce(.init(runtimes: [Self.turns(turns, for: Self.runtime("a", .running))])).queue

        // Arriving together, their order is the IDs' and says nothing here.
        #expect(Set(listed.items.map(\.id)) == Set(turns.map { .unread($0.turnID) }))
        #expect(listed.items.allSatisfy { item in turns.contains { item.kind == .unread($0) } })
    }

    @Test func aRunWithRecordedTurns_neverListsItsEpisode() {
        let finished = Self.turns([], for: Self.runtime("a", .finished))

        #expect(Self.reduce(.init(runtimes: [finished])).queue.items.isEmpty)
    }

    @Test func aLaterTurnJoiningTheRun_updatesItsItemInPlace() {
        let first = Self.reduce(.init(runtimes: [
            Self.turns([Self.recorded("T6", 6...6, .changed(files: 1, added: 1, removed: 0))], for: Self.runtime("a", .finished)),
            Self.runtime("b", .error, pane: Self.paneB, at: 5)
        ])).queue
        let grown = Self.recorded("T6", 6...7, .changed(files: 3, added: 4, removed: 0))

        let next = Self.reduce(.init(runtimes: [
            Self.turns([grown], for: Self.runtime("a", .finished)),
            Self.runtime("b", .error, pane: Self.paneB, at: 5)
        ]), from: first).queue

        #expect(next.items.map(\.id) == first.items.map(\.id))
        #expect(next.items.first?.kind == .unread(grown))
    }

    @Test func aRuntimeThatGoesAway_takesItsItemWithIt() {
        let listed = Self.reduce(.init(runtimes: [Self.runtime("a", .error)])).queue
        #expect(Self.reduce(.init(runtimes: []), from: listed).queue.items.isEmpty)
    }

    @Test(arguments: [AgentState.running, .compacting, .idle, .unknown])
    func aRuntimeNotWaiting_listsNothing(_ state: AgentState) {
        #expect(Self.reduce(.init(runtimes: [Self.runtime("a", state)])).queue.items.isEmpty)
    }

    @Test func aRuntimeInNoPane_listsNothing() {
        let unattached = RuntimeFact(
            runtimeID: "a", provider: .claude, paneIDs: [], tabID: nil, projectID: nil,
            state: .error, updatedAt: Self.start, episodeToken: "1", isEpisodeRead: false, detail: nil
        )
        #expect(Self.reduce(.init(runtimes: [unattached])).queue.items.isEmpty)
    }

    // MARK: - Launch failures

    @Test func aFailure_isAStopOnTheSessionRow_newForEachFailure() {
        let root = URL(fileURLWithPath: "/tmp/weir-wt/")
        let projectID = UUID()
        func failure(_ token: String) -> AttentionQueueReducer.LaunchFailure {
            .init(projectID: projectID, worktreeRoot: root, stage: .setup(stepIndex: 0), logTail: "boom", token: token, failedAt: Date())
        }
        let (first, effects) = AttentionQueueReducer.reduce(AttentionQueue(), input: .init(launchFailures: [failure("1")]))
        let item = first.items.first
        #expect(first.items.count == 1)
        #expect(item?.kind == .stop(.launchFailed(.setup(stepIndex: 0), logTail: "boom")))
        #expect(item?.subject == .sessionRow(projectID: projectID, worktreeRoot: root))
        #expect(item?.subject.isSessionRow(at: URL(fileURLWithPath: "/tmp/weir-wt")) == true)
        #expect(!effects.isEmpty)

        let (second, _) = AttentionQueueReducer.reduce(first, input: .init(launchFailures: [failure("2")]))
        #expect(second.items.count == 1)
        #expect(second.items.first?.id != item?.id)
        let (cleared, _) = AttentionQueueReducer.reduce(second, input: .init())
        #expect(cleared.items.isEmpty)
    }

    // MARK: - Order

    @Test func itemsArrivingInOnePass_areAppendedOldestFirst() {
        let later = Self.runtime("late", .error, pane: Self.paneA, at: 9)
        let sooner = Self.runtime("soon", .error, pane: Self.paneB, at: 1)
        let queue = Self.reduce(.init(runtimes: [later, sooner])).queue
        #expect(queue.items.map(\.subject.paneID) == [Self.paneB, Self.paneA])
    }

    @Test func itemsKeepTheOrderTheyArrivedIn_notTheirUrgency() {
        let unread = Self.runtime("a", .finished, pane: Self.paneA, at: 0)
        let stop = Self.runtime("b", .error, pane: Self.paneB, at: 5)
        let first = Self.reduce(.init(runtimes: [unread, stop])).queue
        #expect(first.items.map(\.subject.paneID) == [Self.paneA, Self.paneB])

        // A request arriving later goes last, however urgent.
        let held = Self.request(pane: UUID(), at: 10)
        let second = Self.reduce(.init(runtimes: [unread, stop], approvals: [held]), from: first).queue
        #expect(second.items.last?.id == .approval(held.fact.key))

        // A change in one item's content leaves it where it is.
        let reworded = Self.runtime("b", .error, pane: Self.paneB, at: 5, detail: "Now with a reason")
        let third = Self.reduce(.init(runtimes: [unread, reworded], approvals: [held]), from: second).queue
        #expect(third.items.map(\.id) == second.items.map(\.id))
        #expect(third.items[1].kind == .stop(.error("Now with a reason")))
    }

    /// A worktree deleted outside Weir is one stop of its workspace row,
    /// listed from when the sync found it gone.
    @Test func aMissingWorktree_isOneStopOfItsRow() {
        let project = UUID()
        let root = URL(fileURLWithPath: "/tmp/gone")
        let missing = AttentionQueueReducer.MissingWorktree(projectID: project, worktreeRoot: root, missingSince: Self.start)
        let first = Self.reduce(.init(missingWorktrees: [missing])).queue
        #expect(first.items.map(\.kind) == [.stop(.worktreeMissing)])
        #expect(first.items.first?.subject == .sessionRow(projectID: project, worktreeRoot: root))
        #expect(first.items.first?.arrivedAt == Self.start)
        // Seen again on the next pass, it is the same item; back, it goes.
        #expect(Self.reduce(.init(missingWorktrees: [missing]), from: first).queue == first)
        #expect(Self.reduce(.init(), from: first).queue.items.isEmpty)
    }
}
