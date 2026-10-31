// ApprovalCardModelTests.swift
// Weir — what the approval card offers in each state, how it words the time
// left and its heading, and where its keyboard starts.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ApprovalCardModelTests {
    private nonisolated static let now = SuspendingClock.now

    @Test("the card names a request by what its tool does, in three forms as the decision bar does")
    func kindLabel_hasAFormForEachAction() {
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        func label(_ action: PromptApproval.Action, _ locale: Locale) -> String {
            ApprovalCardModel.kindLabel(isQuestion: false, action: action).resolved(in: locale)
        }
        #expect(label(.fileChange, en) == "Wants to change files")
        #expect(label(.command, en) == "Wants to run a command")
        #expect(label(.other, en) == "Asking for approval")
        #expect(label(.other, ja) == "承認を求めています")
        #expect(ApprovalCardModel.kindLabel(isQuestion: true, action: .other).resolved(in: en) == "Question")
    }

    private static func model(
        _ state: ApprovalRequestState,
        isAnsweredElsewhere: Bool = false,
        hasFailedDecision: Bool = false
    ) -> ApprovalCardModel? {
        var entry = ApprovalLedger.Entry(
            presentation: ApprovalPresentation.test(summary: "rm -rf build"),
            state: state,
            firstSeenAt: Date()
        )
        entry.isAnsweredElsewhere = isAnsweredElsewhere
        return ApprovalCardModel(entry: entry, hasFailedDecision: hasFailedDecision)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let state: ApprovalRequestState
        var isAnsweredElsewhere = false
        var hasFailedDecision = false
        /// Nil for both when the card closes.
        let actions: ApprovalCardModel.Actions?
        let status: ApprovalCardModel.Status?
        var showsTimeLeft = false

        var testDescription: String {
            "\(state)\(isAnsweredElsewhere ? " elsewhere" : "")\(hasFailedDecision ? " failed" : "")"
        }
    }

    private typealias Status = ApprovalCardModel.Status

    private nonisolated static let table: [Row] = [
        Row(state: .held, actions: .decide, status: Status.none, showsTimeLeft: true),
        Row(state: .sending(.allowOnce, since: now), actions: .sending, status: Status.none, showsTimeLeft: true),
        Row(
            state: .sendFailed(.deny, error: "offline"),
            hasFailedDecision: true,
            actions: .decide,
            status: .sendFailed,
            showsTimeLeft: true
        ),
        // A failed background hand-off: nobody pressed anything.
        Row(
            state: .sendFailed(.delegate, error: "offline"),
            actions: .decide,
            status: Status.none,
            showsTimeLeft: true
        ),
        Row(state: .handedToTerminal(since: now), actions: .openPane, status: .handedToTerminal),
        // Past its deadline only the agent's own prompt answers, so the card
        // offers the pane, as the Needs Attention list does.
        Row(state: .timedOut, actions: .openPane, status: .timedOut),
        Row(
            state: .answered(.allowOnce),
            isAnsweredElsewhere: true,
            actions: ApprovalCardModel.Actions.none,
            status: .alreadyAnswered
        ),
        // Closed.
        Row(state: .answered(.allowOnce), actions: nil, status: nil),
        Row(state: .withdrawn, actions: nil, status: nil),
        Row(state: .unknownResult, actions: nil, status: nil)
    ]

    @Test(arguments: table)
    func eachState_offersItsActions(_ row: Row) {
        let model = Self.model(
            row.state,
            isAnsweredElsewhere: row.isAnsweredElsewhere,
            hasFailedDecision: row.hasFailedDecision
        )
        #expect(model?.actions == row.actions)
        #expect(model?.status == row.status)
        #expect((model?.showsTimeLeft ?? false) == row.showsTimeLeft)
    }

    @Test(arguments: [
        (Duration.seconds(522), "8:42"),
        (Duration.milliseconds(521_200), "8:42"),
        (Duration.seconds(59), "0:59"),
        (Duration.milliseconds(1), "0:01"),
        (Duration.zero, "0:00")
    ])
    func timeLeft_isWrittenAsMinutesAndSeconds(_ remaining: Duration, _ text: String) {
        #expect(ApprovalCardModel.clockText(for: remaining) == text)
    }

    @Test("after the reason, the time left is one phrase with its mark, so a line breaks only before it")
    func timeLeftAfterReason_isGluedToItsMarkAndItsWord() {
        let noBreakSpace = "\u{00A0}"
        let en = Locale(identifier: "en")
        let ja = Locale(identifier: "ja")
        #expect(ApprovalCardModel.timeLeftText(for: .seconds(522), locale: en) == "8:42 left")
        #expect(ApprovalCardModel.timeLeftText(for: .seconds(522), locale: ja) == "残り 8:42")
        #expect(ApprovalCardModel.timeLeftAfterReason(for: .seconds(522), locale: en) == "·\(noBreakSpace)8:42\(noBreakSpace)left")
        #expect(ApprovalCardModel.timeLeftAfterReason(for: .seconds(522), locale: ja) == "·\(noBreakSpace)残り\(noBreakSpace)8:42")
    }

    @Test func theCardsHeading_placesTheRequest_asTheNeedsAttentionListDoes() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "a", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let item = try #require(queue.items.first)
        // The session by its sidebar row's name, as the list names it.
        let name = SessionSidebarModel.rowName(of: tab.container, in: session, locale: Locale(identifier: "en"))

        #expect(ApprovalCardModel.place(of: item, in: session, projectsInOtherWindows: [], locale: Locale(identifier: "en"))
            == "\(name) · weir")
        // Shown by another window: going there brings that window forward.
        #expect(ApprovalCardModel.place(of: item, in: session, projectsInOtherWindows: [project.id], locale: Locale(identifier: "ja"))
            == "\(name) · weir（別のウインドウ）")
    }

    @Test func aRequestInNoPane_hasNoPlaceInTheHeading() {
        let (session, _) = WorkspaceSessionFixture.withProject(name: "weir")
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("a"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .unplaced(provider: .claude),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("b"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "b", provider: .claude, paneID: UUID(), tabID: UUID(), projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 1)
        )
        // Not "Claude Claude": the heading already names the agent.
        for item in queue.items {
            #expect(ApprovalCardModel.place(of: item, in: session, projectsInOtherWindows: [], locale: Locale(identifier: "en")) == nil)
        }
        #expect(queue.items.count == 2)
    }

    @Test func theRequestsOwnWords_showOnlyWhenTheySayMoreThanItsSummary() {
        #expect(ApprovalCardModel.visibleDescription("  Edit the config  ", summary: "Edit") == "Edit the config")
        #expect(ApprovalCardModel.visibleDescription("Edit\n", summary: " Edit ") == nil, "the summary again")
        #expect(ApprovalCardModel.visibleDescription("   ", summary: nil) == nil)
        #expect(ApprovalCardModel.visibleDescription(nil, summary: "Edit") == nil)
    }

    @Test func theToolInput_growsWithItsLines_upToItsCap() {
        func height(_ input: String) -> CGFloat {
            ApprovalCardModel.detailsHeight(of: input, lineHeight: 15, verticalInsets: 12, maxHeight: 180)
        }
        #expect(height("") == 27, "at least one line")
        #expect(height("a\nb\nc") == 57)
        #expect(height(String(repeating: "x\n", count: 40)) == 180, "it scrolls past the cap")
    }

    @Test func sendAnswer_takesOnlyAnAnswerWithinTheLimit_andSaysWhenItIsTooLong() {
        let short = ApprovalResolution.answer(["q": "yes"])
        let long = ApprovalResolution.answer(["q": String(repeating: "x", count: ApprovalResolution.maximumEncodedBytes)])
        #expect(ApprovalCardModel.canSend(short))
        #expect(!ApprovalCardModel.answerExceedsLimit(short))
        #expect(!ApprovalCardModel.canSend(long))
        #expect(ApprovalCardModel.answerExceedsLimit(long))
        #expect(!ApprovalCardModel.canSend(nil), "a question left unanswered")
        #expect(!ApprovalCardModel.answerExceedsLimit(nil))
        #expect(ApprovalCardModel.isLastQuestion(1, of: 2))
        #expect(!ApprovalCardModel.isLastQuestion(0, of: 2))
    }

    @Test func theKeyboard_startsOnWhatCommitsNothing_thenThePane_thenClose() {
        #expect(ApprovalCardModel.initialFocus(for: .decide, canOpenPane: true) == .secondaryAction)
        #expect(ApprovalCardModel.initialFocus(for: .openPane, canOpenPane: true) == .primaryAction)
        #expect(ApprovalCardModel.initialFocus(for: .openPane, canOpenPane: false) == .close)
        #expect(ApprovalCardModel.initialFocus(for: .sending, canOpenPane: true) == .close)
        #expect(ApprovalCardModel.initialFocus(for: .none, canOpenPane: true) == .close)
    }
}
