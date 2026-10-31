// MenuBarModelTests.swift
// Weir — the menu bar extra's items: what it lists, in what words, and what each one does.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Weir

struct MenuBarModelTests {
    private static func row(
        _ id: AttentionItemID,
        _ state: NeedsAttentionListModel.RowState,
        action: NeedsAttentionListModel.RowAction? = nil
    ) -> NeedsAttentionListModel.Row {
        NeedsAttentionListModel.Row(
            id: id,
            state: state,
            title: "s",
            place: nil,
            fact: "f",
            placeLead: "",
            action: action,
            arrivedAt: Date()
        )
    }

    private static let approvalKey = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
    private static let approvalID = AttentionItemID.approval(approvalKey)
    private static let stopID = AttentionItemID.stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1"))
    private static let unreadID = AttentionItemID.unread(TurnID("t"))

    /// An approval's item, its row offering Answer… as the list's does
    /// while the broker takes a decision, unless `action` says otherwise.
    private static func item(
        _ offer: MenuBarApprovalRule.Offer,
        command: String? = "make test",
        isQuestion: Bool = false,
        action: NeedsAttentionListModel.RowAction? = .answer(approvalKey),
        hasFailedToSend: Bool = false
    ) -> MenuBarModel.Item? {
        let request = MenuBarModel.Request(command: command, isQuestion: isQuestion, offer: offer, hasFailedToSend: hasFailedToSend)
        return MenuBarModel(
            rows: [row(approvalID, isQuestion ? .question : .approval, action: action)],
            request: { _ in request },
            canResume: { _ in true },
            resetNotice: { _ in nil }
        ).items.first
    }

    @Test func init_keepsTheListOrder() {
        let model = MenuBarModel(
            rows: [Self.row(Self.approvalID, .approval), Self.row(Self.unreadID, .unread)],
            request: { $0 == Self.approvalID ? MenuBarModel.Request(command: "ls", isQuestion: false, offer: .allowOrDeny) : nil },
            canResume: { _ in true },
            resetNotice: { _ in nil }
        )
        #expect(model.items.map(\.id) == [Self.approvalID, Self.unreadID])
        #expect(model.items.last?.request == nil)
    }

    /// Under the row are only the actions that settle it in place. Going to
    /// Weir is the row itself, or the list's Answer… beside it.
    @Test func actions_settleOnlyWhatTheRowCanSettleInPlace() {
        #expect(Self.item(.allowOrDeny)?.actions == [.allowOnce, .deny])
        #expect(Self.item(.highImpact)?.actions == [])
        #expect(Self.item(.tooLong)?.actions == [])
        #expect(Self.item(.notACommand, command: nil)?.actions == [])
        #expect(Self.item(.answerInWeir, command: nil, isQuestion: true)?.actions == [])
        #expect(Self.item(.openPane, command: nil, isQuestion: true, action: nil)?.actions == [])
        #expect(Self.item(.handedToTerminal, action: nil)?.actions == [])
        #expect(Self.item(.timedOut, action: nil)?.actions == [])
        #expect(Self.item(.answered, action: nil)?.actions == [])
        #expect(Self.item(.sending, action: nil)?.actions == [])
    }

    /// The menu allows only what the list would let the card answer: a row
    /// without Answer… (the broker no longer takes a decision) offers
    /// neither button, whatever the command.
    @Test func allowAndDeny_needTheListsAnswer() {
        #expect(Self.item(.allowOrDeny, action: .answer(Self.approvalKey))?.actions == [.allowOnce, .deny])
        #expect(Self.item(.allowOrDeny, action: nil)?.actions == [])
        #expect(Self.item(.allowOrDeny, action: nil)?.command == nil)
    }

    @Test func command_showsWhole_onlyOverAllowAndDeny() {
        #expect(Self.item(.allowOrDeny)?.command == "make test")
        #expect(Self.item(.tooLong)?.command == nil)
        #expect(Self.item(.highImpact)?.command == nil)
    }

    @Test func notes_sayWhyTheMenuDoesNotAnswer() {
        #expect(Self.item(.allowOrDeny)?.note == nil)
        #expect(Self.item(.notACommand, command: nil)?.note == nil)
        #expect(Self.item(.highImpact)?.note == .highImpact)
        #expect(Self.item(.tooLong)?.note == .tooLong)
        #expect(Self.item(.notShownWhole)?.note == .notShownWhole)
        #expect(Self.item(.notShownWhole)?.actions == [])
        #expect(Self.item(.notShownWhole)?.command == nil)
        #expect(Self.item(.sending)?.note == .sending)
        #expect(Self.item(.answered)?.note == .answered)
        #expect(Self.item(.handedToTerminal)?.note == .handedToTerminal)
        #expect(Self.item(.handedToTerminal, command: nil, isQuestion: true)?.note == .handedToTerminal)
        #expect(Self.item(.timedOut)?.note == .timedOut)
    }

    @Test func notes_aFailedSendIsOfferedAgainAndSaysSo() {
        let item = Self.item(.allowOrDeny, hasFailedToSend: true)
        #expect(item?.actions == [.allowOnce, .deny])
        #expect(item?.note == .sendFailed)
    }

    @Test func init_onlyStopsResume() {
        let model = MenuBarModel(
            rows: [Self.row(Self.stopID, .stopped), Self.row(Self.unreadID, .unread)],
            request: { _ in nil },
            canResume: { _ in true },
            resetNotice: { _ in nil }
        )
        #expect(model.items.map(\.actions) == [[.resume], []])
    }

    @Test func init_stopThatCannotResume_offersNothingInPlace() {
        let model = MenuBarModel(
            rows: [Self.row(Self.stopID, .stopped)],
            request: { _ in nil },
            canResume: { _ in false },
            resetNotice: { _ in nil }
        )
        #expect(model.items.first?.actions == [])
    }

    @Test func onlyTheButtonThatSettlesAnItem_isPrimary() {
        // Allowing, resuming, or asking to hear of the reset is blue;
        // Deny is red text.
        let primaries = [MenuBarModel.Action.allowOnce, .deny, .resume, .notifyAtReset].filter(\.isPrimary)
        #expect(primaries == [.allowOnce, .resume, .notifyAtReset])
        #expect(MenuBarModel.Action.deny.isRefusal)
        #expect(!MenuBarModel.Action.resume.isRefusal)
    }

    /// Tab goes through the buttons under the row, then the list's own.
    @Test func keyboardActionCount_isTheButtonsUnderTheRow_andTheRowsOwn() {
        #expect(Self.item(.allowOrDeny)?.keyboardActionCount == 3)
        #expect(Self.item(.highImpact)?.keyboardActionCount == 1)
        #expect(Self.item(.sending, action: nil)?.keyboardActionCount == 0)
    }

    /// Tab's places, in order, and what each one presses: the row, the
    /// buttons under it, then the list's own; past the end, nothing.
    @Test func controlAt_namesWhatEachPlacePresses() {
        let item = Self.item(.allowOrDeny)
        #expect(item?.control(at: nil) == .row)
        #expect(item?.control(at: 0) == .inPlace(.allowOnce))
        #expect(item?.control(at: 1) == .inPlace(.deny))
        #expect(item?.control(at: 2) == .rowAction(.answer(Self.approvalKey)))
        #expect(item?.control(at: 3) == nil)

        let stop = MenuBarModel(
            rows: [Self.row(Self.stopID, .stopped)],
            request: { _ in nil },
            canResume: { _ in true },
            resetNotice: { _ in nil }
        ).items.first
        #expect(stop?.control(at: 0) == .inPlace(.resume))
        #expect(stop?.control(at: 1) == nil)
        // A request left to the terminal has no button: only the row,
        // which goes to its pane.
        #expect(Self.item(.handedToTerminal, action: nil)?.control(at: 0) == nil)
    }

    /// Going to a request's pane shows it, which hands the request to the
    /// terminal; VoiceOver says so on the row.
    @Test func openHint_saysARequestIsAnsweredInTheTerminal_atItsPane() {
        func hint(_ state: NeedsAttentionListModel.RowState, isInPane: Bool) -> MenuBarModel.OpenHint? {
            MenuBarModel(
                rows: [Self.row(Self.approvalID, state)],
                request: { _ in nil },
                canResume: { _ in false },
                resetNotice: { _ in nil },
                isInPane: { _ in isInPane }
            ).items.first?.openHint
        }
        #expect(hint(.approval, isInPane: true) == .goesToPaneToAnswerInTerminal)
        #expect(hint(.question, isInPane: true) == .goesToPaneToAnswerInTerminal)
        #expect(hint(.response, isInPane: true) == .goesToPaneToAnswerInTerminal)
        #expect(hint(.approval, isInPane: false) == .opensCard, "no pane: the row opens the card")
        #expect(hint(.question, isInPane: false) == .opensCard)
        #expect(hint(.signIn, isInPane: true) == .goesToPane, "a sign-in is not answered")
        #expect(hint(.stopped, isInPane: true) == .goesToPane)
        #expect(hint(.unread, isInPane: true) == .goesToPane)
    }
}
