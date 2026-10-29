// AttentionQueueTests.swift
// Limpid — the attention list's order, numbering, and per-pane priority.

import Foundation
import Testing
@testable import Limpid

struct AttentionQueueTests {
    private static let pane = UUID()
    private static let otherPane = UUID()
    private static let start = Date(timeIntervalSince1970: 1000)

    private static func subject(pane: UUID = pane) -> AttentionSubject {
        .runtime(id: "run", provider: .claude, paneID: pane, tabID: UUID(), projectID: nil)
    }

    private static func approvalKey() -> ApprovalKey {
        ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
    }

    private static func fact(
        _ key: ApprovalKey,
        isQuestion: Bool = false,
        supportsNativeAnswer: Bool = true,
        state: ApprovalRequestState = .timedOut
    ) -> ApprovalFact {
        ApprovalFact(
            key: key,
            provider: .claude,
            isQuestion: isQuestion,
            supportsNativeAnswer: supportsNativeAnswer,
            state: state,
            deadline: nil
        )
    }

    private static func stopID(_ token: String) -> AttentionItemID {
        .stop(EpisodeKey(origin: .runtime("run"), episodeToken: token))
    }

    private static func unread(_ id: String) -> (AttentionItemID, AttentionItemKind) {
        let turn = TurnID(id)
        return (.unread(turn), .unread(UnreadTurn(turnID: turn, changes: .unknown)))
    }

    @Test func insert_numbersItemsInArrivalOrder() {
        var queue = AttentionQueue()
        let (first, firstKind) = Self.unread("a")
        let (second, secondKind) = Self.unread("b")
        let isFirstInserted = queue.insert(id: first, kind: firstKind, subject: Self.subject(), arrivedAt: Self.start)
        let isSecondInserted = queue.insert(id: second, kind: secondKind, subject: Self.subject(), arrivedAt: Self.start)

        #expect(isFirstInserted && isSecondInserted)

        #expect(queue.items.map(\.id) == [first, second])
        #expect(queue.items.map(\.arrivalSequence) == [1, 2])
    }

    @Test func insert_sameIDTwice_keepsTheFirstPlace() {
        var queue = AttentionQueue()
        let (first, firstKind) = Self.unread("a")
        let (second, secondKind) = Self.unread("b")
        queue.insert(id: first, kind: firstKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: second, kind: secondKind, subject: Self.subject(), arrivedAt: Self.start)

        let isInsertedAgain = queue.insert(id: first, kind: firstKind, subject: Self.subject(), arrivedAt: Self.start)

        #expect(!isInsertedAgain)
        #expect(queue.items.map(\.id) == [first, second])
    }

    @Test func update_changesContentWithoutMovingTheItem() {
        var queue = AttentionQueue()
        let key = Self.approvalKey()
        let (other, otherKind) = Self.unread("a")
        queue.insert(id: .approval(key), kind: .approval(Self.fact(key)), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: other, kind: otherKind, subject: Self.subject(), arrivedAt: Self.start)

        queue.update(id: .approval(key), kind: .approval(Self.fact(key, state: .withdrawn)))

        #expect(queue.items.map(\.id) == [.approval(key), other])
        #expect(queue.items.first?.arrivalSequence == 1)
        #expect(queue.items.first?.kind == .approval(Self.fact(key, state: .withdrawn)))
    }

    @Test func update_withASubject_movesThePaneButNotThePlace() {
        var queue = AttentionQueue()
        let (first, firstKind) = Self.unread("a")
        let (second, secondKind) = Self.unread("b")
        queue.insert(id: first, kind: firstKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: second, kind: secondKind, subject: Self.subject(), arrivedAt: Self.start)

        queue.update(id: first, kind: firstKind, subject: Self.subject(pane: Self.otherPane))

        #expect(queue.items.map(\.id) == [first, second])
        #expect(queue.items(inPane: Self.otherPane).map(\.id) == [first])
    }

    @Test func update_unknownID_doesNothing() {
        var queue = AttentionQueue()
        let (id, kind) = Self.unread("a")
        queue.update(id: id, kind: kind)
        #expect(queue.items.isEmpty)
    }

    @Test func remove_keepsTheRestInOrderAndNumbersAreNotReused() {
        var queue = AttentionQueue()
        let ids = ["a", "b", "c"].map(Self.unread)
        for (id, kind) in ids {
            queue.insert(id: id, kind: kind, subject: Self.subject(), arrivedAt: Self.start)
        }
        queue.remove(ids[1].0)
        let (late, lateKind) = Self.unread("d")
        queue.insert(id: late, kind: lateKind, subject: Self.subject(), arrivedAt: Self.start)

        #expect(queue.items.map(\.id) == [ids[0].0, ids[2].0, late])
        #expect(queue.items.map(\.arrivalSequence) == [1, 3, 4])
    }

    @Test func itemsInPane_leavesOutOtherPanesAndSessionRows() {
        var queue = AttentionQueue()
        let (mine, mineKind) = Self.unread("a")
        let (theirs, theirsKind) = Self.unread("b")
        queue.insert(id: mine, kind: mineKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: theirs, kind: theirsKind, subject: Self.subject(pane: Self.otherPane), arrivedAt: Self.start)
        queue.insert(
            id: .stop(EpisodeKey(origin: .sessionRow(worktreePath: "/tmp/w"), episodeToken: "1")),
            kind: .stop(.worktreeMissing),
            subject: .sessionRow(projectID: nil, worktreeRoot: URL(fileURLWithPath: "/tmp/w")),
            arrivedAt: Self.start
        )

        #expect(queue.items(inPane: Self.pane).map(\.id) == [mine])
    }

    @Test func counts_byKind() {
        var queue = AttentionQueue()
        let approval = Self.approvalKey()
        let question = Self.approvalKey()
        queue.insert(id: .approval(approval), kind: .approval(Self.fact(approval)), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(
            id: .question(question),
            kind: .question(Self.fact(question, isQuestion: true)),
            subject: Self.subject(),
            arrivedAt: Self.start
        )
        queue.insert(id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivedAt: Self.start)
        let (unread, unreadKind) = Self.unread("a")
        queue.insert(id: unread, kind: unreadKind, subject: Self.subject(), arrivedAt: Self.start)

        let counts = queue.counts()
        #expect(counts == AttentionCounts(approvals: 1, questions: 1, stops: 1, unread: 1))
        #expect(counts.total == 4)
        #expect(counts.hasBlockingItems)
    }

    /// A sign-in is counted on its own, so the count names it rather than
    /// calling it a response.
    @Test func counts_aSignIn_onItsOwn() {
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("run"), episodeToken: "1")),
            kind: .prompt(.signIn),
            subject: Self.subject(),
            arrivedAt: Self.start
        )
        #expect(queue.counts() == AttentionCounts(signIns: 1))
        #expect(AttentionSummaryText.breakdown(queue.counts(), locale: Locale(identifier: "en")) == ["1 Sign-in"])
        #expect(AttentionSummaryText.breakdown(queue.counts(), locale: Locale(identifier: "ja")) == ["サインイン 1"])
        #expect(queue.counts().hasBlockingItems)
    }

    @Test func counts_onlyUnread_isNotBlocking() {
        var queue = AttentionQueue()
        let (unread, unreadKind) = Self.unread("a")
        queue.insert(id: unread, kind: unreadKind, subject: Self.subject(), arrivedAt: Self.start)
        #expect(!queue.counts().hasBlockingItems)
        #expect(AttentionQueue().counts().total == 0)
    }

    @Test func dominant_questionThenApprovalThenStopThenUnread() {
        var queue = AttentionQueue()
        let approval = Self.approvalKey()
        let question = Self.approvalKey()
        let (unread, unreadKind) = Self.unread("a")
        // Inserted lowest rank first, so arrival order alone would pick wrongly.
        queue.insert(id: unread, kind: unreadKind, subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: .approval(approval), kind: .approval(Self.fact(approval)), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(
            id: .question(question),
            kind: .question(Self.fact(question, isQuestion: true)),
            subject: Self.subject(),
            arrivedAt: Self.start
        )

        var items = queue.items(inPane: Self.pane)
        #expect(PanePriority.dominant(items)?.id == .question(question))
        items.removeAll { $0.id == .question(question) }
        #expect(PanePriority.dominant(items)?.id == .approval(approval))
        items.removeAll { $0.id == .approval(approval) }
        #expect(PanePriority.dominant(items)?.id == Self.stopID("1"))
        items.removeAll { $0.id == Self.stopID("1") }
        #expect(PanePriority.dominant(items)?.id == unread)
        #expect(PanePriority.dominant([]) == nil)
    }

    @Test func dominant_amongEqualRanks_theEarliestArrival() {
        var queue = AttentionQueue()
        queue.insert(id: Self.stopID("1"), kind: .stop(.processExited), subject: Self.subject(), arrivedAt: Self.start)
        queue.insert(id: Self.stopID("2"), kind: .stop(.worktreeMissing), subject: Self.subject(), arrivedAt: Self.start)
        #expect(PanePriority.dominant(queue.items.reversed())?.id == Self.stopID("1"))
    }

    @Test func canAnswerInLimpid_followsTheRequestState() {
        let key = Self.approvalKey()
        func item(_ fact: ApprovalFact) -> AttentionItem {
            AttentionItem(id: .approval(key), kind: .approval(fact), subject: Self.subject(), arrivalSequence: 1, arrivedAt: Self.start)
        }
        #expect(item(Self.fact(key, state: .sendFailed(.allowOnce, error: "x"))).canAnswerInLimpid)
        #expect(!item(Self.fact(key, state: .timedOut)).canAnswerInLimpid)
        #expect(!item(Self.fact(key, state: .answered(.deny))).canAnswerInLimpid)
        // Codex questions are always answered in the TUI.
        #expect(!item(Self.fact(key, isQuestion: true, supportsNativeAnswer: false, state: .sendFailed(.deny, error: "x")))
            .canAnswerInLimpid)
        let stop = AttentionItem(
            id: Self.stopID("1"),
            kind: .stop(.processExited),
            subject: Self.subject(),
            arrivalSequence: 1,
            arrivedAt: Self.start
        )
        #expect(!stop.canAnswerInLimpid)
    }

    @Test func itemID_roundTripsThroughJSON() throws {
        let ids: [AttentionItemID] = [
            .approval(Self.approvalKey()),
            .question(Self.approvalKey()),
            .stop(EpisodeKey(origin: .sessionRow(worktreePath: "/tmp/w"), episodeToken: "7")),
            .unread(TurnID("t1"))
        ]
        let data = try JSONEncoder().encode(ids)
        #expect(try JSONDecoder().decode([AttentionItemID].self, from: data) == ids)
    }

    @Test func episodeKeyForASessionRow_ignoresATrailingSlash() {
        let withSlash = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/w/", isDirectory: true))
        let without = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/w", isDirectory: false))
        let dotted = EpisodeKey.Origin.sessionRow(worktreeRoot: URL(fileURLWithPath: "/tmp/x/../w"))
        #expect(withSlash == without)
        #expect(dotted == without)
        #expect(without == .sessionRow(worktreePath: "/tmp/w"))
    }

    @Test func conversationKey_readsTheRustSpelling() throws {
        let json = Data(#"{"provider":"codex","conversationId":"abc","isFallback":true}"#.utf8)
        let key = try JSONDecoder().decode(ConversationKey.self, from: json)
        #expect(key == ConversationKey(provider: .codex, conversationID: "abc", isFallback: true))
        #expect(try JSONDecoder().decode(TurnID.self, from: Data(#""t9""#.utf8)) == TurnID("t9"))
    }

    @Test func aProjectsCounts_areItsItemsAlone_andTheOthers_leaveOutItemsInNoProject() {
        let here = UUID()
        let there = UUID()
        let unread = UnreadTurn(turnID: TurnID("b#1"), changes: .unknown)
        var queue = AttentionQueue()
        for (offset, (name, project, kind)) in [
            ("a", Optional(here), AttentionItemKind.stop(.processExited)),
            ("b", there, .unread(unread)),
            ("c", here, .prompt(PromptWait(detail: nil))),
            ("d", nil, .stop(.error(nil)))
        ].enumerated() {
            queue.insert(
                id: Self.stopID(name),
                kind: kind,
                subject: .runtime(id: name, provider: .claude, paneID: UUID(), tabID: nil, projectID: project),
                arrivedAt: Self.start.addingTimeInterval(TimeInterval(offset))
            )
        }

        #expect(queue.counts(inProject: here) == AttentionCounts(prompts: 1, stops: 1))
        #expect(queue.counts(inProject: there) == AttentionCounts(unread: 1))
        #expect(queue.counts(inProjectsOtherThan: here) == AttentionCounts(unread: 1))
        #expect(queue.counts(inProjectsOtherThan: nil) == AttentionCounts(prompts: 1, stops: 1, unread: 1))
    }

    @Test func aWaitAtThePrompt_countsAsTheRequestItsRecordNames_elseAsAResponse() {
        var queue = AttentionQueue()
        for (offset, kind) in [
            AttentionItemKind.prompt(PromptWait(detail: "Bash: ls")),
            .prompt(.question(detail: "Which color?")),
            .prompt(PromptWait(detail: "Which color?"))
        ].enumerated() {
            queue.insert(
                id: Self.stopID("w\(offset)"),
                kind: kind,
                subject: .runtime(id: "w\(offset)", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
                arrivedAt: Self.start.addingTimeInterval(TimeInterval(offset))
            )
        }
        #expect(queue.counts() == AttentionCounts(approvals: 1, questions: 1, prompts: 1))
    }
}
