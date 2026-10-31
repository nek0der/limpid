// TurnProtectionTests.swift
// Weir — the turns no retention limit may take, the conversations a deletion empties, and the sweep in the shape the
// Rust rules read it.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
@Suite("Turn protection")
struct TurnProtectionTests {
    private typealias Fixture = TurnSummaryFixture
    private static let now = Date(timeIntervalSince1970: 1_791_763_200)
    private static let other = ConversationKey(provider: .codex, conversationID: "c2", isFallback: false)

    private static func protection(_ sources: TurnProtection.Sources) -> TurnProtection? {
        TurnProtection.of(sources, now: now)
    }

    @Test func unreadTurnsAreKept_andOpenRangesHeld_notRunningOrUnpromptedOnes() throws {
        let read = try Fixture.turn("read", changes: Fixture.changedFiles, number: 1)
        let unread = try Fixture.turn("unread", changes: Fixture.changedFiles, number: 2)
        let running = try Fixture.turn("running", phase: "started", number: 3)
        let unprompted = try Fixture.turn("unprompted", hasPrompt: false, number: 4)
        // A range needs both snapshots of its turns.
        var trees = TurnSummaryFixture.Extras()
        trees.beginTree = SnapshotTree(tree: Fixture.tree("b", 5), root: "/repo")
        let inRange = try Fixture.turn(
            "ranged",
            changes: Fixture.changedFiles,
            number: 5,
            endTree: SnapshotTree(tree: Fixture.tree("e", 5), root: "/repo"),
            extras: trees
        )
        let range = try #require(ReviewTurnRange(turns: [inRange]))

        let protection = try #require(Self.protection(TurnProtection.Sources(
            hasLoaded: true,
            history: [Fixture.conversation: [read, unread, running, unprompted, inRange]],
            isRead: { $0.turnID != unread.turnID },
            rangeTurnIDs: Set(range.turnIDs),
            shownConversations: [Fixture.conversation]
        )))

        #expect(protection.protectedTurnIDs == [unread.turnID])
        #expect(protection.heldTurnIDs == [inRange.turnID])
        #expect(protection.shownConversations == [Fixture.conversation])
    }

    @Test func anUnreadTurnOfAClosedSession_isNotKept_andOneOfAnOpenOnePastNinetyDaysIsNot() throws {
        let closed = try Fixture.turn("closed", changes: Fixture.changedFiles, number: 1)
        var old = TurnSummaryFixture.Extras()
        old.startedAt = "2026-06-01T00:00:00Z"
        let ancient = try Fixture.turn("ancient", changes: Fixture.changedFiles, number: 1, extras: old)
        let recent = try Fixture.turn("recent", changes: Fixture.changedFiles, number: 2)

        let protection = try #require(Self.protection(TurnProtection.Sources(
            hasLoaded: true,
            history: [Self.other: [closed], Fixture.conversation: [ancient, recent]],
            isRead: { _ in false },
            shownConversations: [Fixture.conversation]
        )))

        #expect(protection.protectedTurnIDs == [recent.turnID], "unread goes with its session, and at ninety days")
        #expect(protection.unreadPastAge == 1)
    }

    @Test func anUnreadTurnStaysWhileItsPaneIsOpen_evenWithItsAgentGone() throws {
        // The fixture's turns name pane "P"; its conversation runs in none.
        let unread = try Fixture.turn("unread", changes: Fixture.changedFiles, number: 1)
        let sources = { (panes: Set<String>) in
            TurnProtection.Sources(
                hasLoaded: true,
                history: [Self.other: [unread]],
                isRead: { _ in false },
                openPanes: panes
            )
        }

        #expect(try #require(Self.protection(sources(["P"]))).protectedTurnIDs == [unread.turnID])
        #expect(try #require(Self.protection(sources([]))).protectedTurnIDs.isEmpty, "its pane closed")
    }

    @Test func anUnreadTurnIsKeptUpToNinetyDays() throws {
        let day: TimeInterval = 24 * 60 * 60
        let turn = { (age: TimeInterval) in
            var extras = TurnSummaryFixture.Extras()
            extras.startedAt = Self.now.addingTimeInterval(-age).formatted(.iso8601)
            return try Fixture.turn("t\(Int(age))", changes: Fixture.changedFiles, number: Int(age / day), extras: extras)
        }
        let within = try turn(90 * day - 60)
        let past = try turn(90 * day)

        let protection = try #require(Self.protection(TurnProtection.Sources(
            hasLoaded: true,
            history: [Fixture.conversation: [within, past]],
            isRead: { _ in false },
            shownConversations: [Fixture.conversation]
        )))

        #expect(protection.protectedTurnIDs == [within.turnID])
        #expect(protection.unreadPastAge == 1)
    }

    @Test func protection_waitsForTheTurnsToBeRead() throws {
        let turn = try Fixture.turn("a", number: 1)
        #expect(Self.protection(TurnProtection.Sources(
            hasLoaded: false,
            history: [Fixture.conversation: [turn]],
            isRead: { _ in true }
        )) == nil)
    }

    @Test func aTurnReadAMomentAgo_isHeldForItsUndo() throws {
        let marked = try Fixture.turn("marked", number: 1)
        let viewed = try Fixture.turn("viewed", changes: Fixture.changedFiles, number: 2)
        let old = try Fixture.turn("old", number: 1)

        let protection = try #require(Self.protection(TurnProtection.Sources(
            hasLoaded: true,
            history: [Fixture.conversation: [marked, viewed], Self.other: [old]],
            isRead: { _ in true },
            readAt: { $0 == marked.turnID ? Self.now.addingTimeInterval(-60) : Self.now.addingTimeInterval(-3600) },
            lineMovedAt: { $0 == Fixture.conversation ? Self.now.addingTimeInterval(-120) : nil }
        )))

        #expect(protection.heldTurnIDs == [marked.turnID, viewed.turnID], "read an hour ago is read")
        #expect(protection.protectedTurnIDs.isEmpty)
    }

    @Test func aConversationLeftWithNoTurns_losesItsLine_whateverTheHistoryStillHas() throws {
        let first = try Fixture.turn("1", number: 1)
        let second = try Fixture.turn("2", number: 2)

        // A pass during the deletion already dropped the conversation.
        #expect(TurnProtection.conversationsEmptied(
            by: [first.turnID: Fixture.conversation],
            remaining: [],
            history: [:]
        ) == [Fixture.conversation])
        #expect(TurnProtection.conversationsEmptied(
            by: [first.turnID: Fixture.conversation],
            remaining: [],
            history: [Fixture.conversation: [first, second]]
        ).isEmpty, "a turn of it is left")
        #expect(TurnProtection.conversationsEmptied(
            by: [first.turnID: Fixture.conversation, second.turnID: Fixture.conversation, TurnID("x"): nil],
            remaining: [],
            history: [Fixture.conversation: [first, second], Self.other: []]
        ) == [Fixture.conversation], "a turn whose conversation was never known empties none")
    }

    @Test func aConversationWithATurnNotDeletedOrStillOnItsWay_keepsItsLine() throws {
        let first = try Fixture.turn("1", number: 1)
        // The history missed the other turn while it was moved aside.
        #expect(TurnProtection.conversationsEmptied(
            by: [first.turnID: Fixture.conversation],
            remaining: [Fixture.conversation],
            history: [:]
        ).isEmpty)
    }

    @Test func theSweep_reachesTheRulesInTheirShape_sortedSoTheSameInputEncodesAlike() throws {
        let sweep = AgentProjectionTurnSweep(
            limits: TurnRetentionLimits(maxAgeSeconds: 60, maxPerConversation: 3),
            protection: TurnProtection(
                protectedTurnIDs: [TurnID("B"), TurnID("A")],
                heldTurnIDs: [TurnID("D"), TurnID("C")],
                shownConversations: [Fixture.conversation]
            )
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(sweep)) as? [String: Any])

        #expect(object["maxAgeSecs"] as? Int == 60)
        #expect(object["maxPerConversation"] as? Int == 3)
        #expect(object["maxRepositoryBytes"] as? Int == 500 * 1024 * 1024)
        #expect(object["maxTurns"] as? Int == 8000)
        #expect(object["protectedTurnIds"] as? [String] == ["A", "B"])
        #expect(object["heldTurnIds"] as? [String] == ["C", "D"])
        let shown = try #require((object["shownConversations"] as? [[String: Any]])?.first)
        #expect(shown["conversationId"] as? String == "s1")
        #expect(shown["provider"] as? String == "claude")
    }

    /// A restatement on purpose: these are the numbers the README promises,
    /// and lowering one deletes people's turns sooner. It checks no behavior;
    /// it makes changing one a second, deliberate edit.
    @Test func theStandardLimits_areTheOnesTheReadmePromises() {
        #expect(TurnRetentionLimits.standard.maxAgeSeconds == 14 * 24 * 60 * 60)
        #expect(TurnRetentionLimits.standard.maxPerConversation == 200)
        #expect(TurnRetentionLimits.standard.maxRepositoryBytes == 500 * 1024 * 1024)
        #expect(TurnRetentionLimits.standard.maxTurns == 8000)
    }

    /// A closed window's review, kept for its project, holds its range as an
    /// open review tab does: its comment is still being written. A
    /// removed project's lets it go.
    @Test func aParkedReviewsRange_isProtectedFromTheSweep() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "first")
        let second = session.addOrActivateProject(
            rootURL: WorkspaceSessionFixture.projectRootURL("parked"),
            suggestedName: "second"
        )
        session.setActiveContainer(.project(project.id))
        session.primarySelection.projectID = project.id
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        registry.show(registry.primary.id)
        let turn = try TurnSummaryFixture.turn(
            "T7",
            changes: TurnSummaryFixture.changedFiles,
            number: 7,
            endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", 7), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 7), root: "/repo"))
        )
        let range = try #require(ReviewTurnRange(turns: [turn]))
        let writers = ReviewDraftWriterPool(shouldPersist: false)
        // What the sweep keeps of the reviews (`AppState.turnProtection`).
        let protected = { Set(writers.openTurnRanges() + registry.reviewTurnRanges(in: session)) }
        let window = try #require(registry.openInNewWindow(project: second.id, in: session, from: nil))
        do {
            let review = writers.session(root: WorkspaceSessionFixture.projectRootURL("parked-review"))
            review.writer.rememberRange(range)
            window.reviewSession = review
        }
        window.review = ReviewTabState(
            root: "/repo",
            selection: .turn(range, prompt: TurnPrompt(head: nil)),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        window.writeComment()
        #expect(protected() == [range])

        registry.close(window.id, in: session)

        #expect(registry.parkedReviews[second.id]?.tab != nil)
        #expect(window.reviewSession == nil, "the closed window keeps nothing open")
        #expect(protected() == [range])
        // A project removed meanwhile holds nothing open, as the app lets
        // its kept review go.
        session.removeProject(second.id)
        #expect(registry.reviewTurnRanges(in: session).isEmpty)
        registry.forgetProjectsGone(in: session)
        #expect(registry.parkedReviews.isEmpty)
        #expect(protected().isEmpty)
    }
}
