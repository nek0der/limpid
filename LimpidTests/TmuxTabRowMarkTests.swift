// TmuxTabRowMarkTests.swift
// Limpid — checks which mark a mirror tab's row carries for each connection state and warning.

import Foundation
import Testing
@testable import Limpid

struct TmuxTabRowMarkTests {
    @Test func liveTab_withNothingToWarnAbout_hasNoMark() {
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: nil) == nil)
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues()) == nil)
        // Registered, not yet recorded: the mirror is there and says nothing.
        #expect(TmuxTabRowMark.make(connection: nil, hasMirror: true, issues: nil) == nil)
    }

    @Test(arguments: [
        (TmuxTabConnection.connecting, TmuxTabRowMark.Reason.connecting),
        (.disconnected, .disconnected),
        (.unreachable, .unreachable),
        (.serverReplaced, .serverReplaced)
    ])
    func connectionState_isTheOnlyReason(connection: TmuxTabConnection, reason: TmuxTabRowMark.Reason) {
        let issues = TmuxTabIssues(hasDroppedOutput: true, isWindowLargerThanTab: true)
        let mark = TmuxTabRowMark.make(connection: connection, hasMirror: true, issues: issues)
        // A tab that is not live repaints and resizes nothing, so its
        // mirror's warnings are left out.
        #expect(mark?.reasons == [reason])
    }

    /// Such a tab was restored or reopened and nothing feeds it yet, which
    /// its card also reads as disconnected.
    @Test func tabWithoutRecordOrMirror_readsAsDisconnected() {
        #expect(TmuxTabRowMark.make(connection: nil, hasMirror: false, issues: nil)?.reasons == [.disconnected])
    }

    @Test func liveTab_listsEveryWarning_droppedOutputFirst() throws {
        let dropped = TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues(hasDroppedOutput: true))
        #expect(dropped?.reasons == [.droppedOutput])

        let larger = TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues(isWindowLargerThanTab: true))
        #expect(larger?.reasons == [.windowLargerThanTab])

        let both = try #require(TmuxTabRowMark.make(
            connection: .live,
            hasMirror: true,
            issues: TmuxTabIssues(hasDroppedOutput: true, isWindowLargerThanTab: true)
        ))
        #expect(both.reasons == [.droppedOutput, .windowLargerThanTab])
        #expect(both.primary == .droppedOutput)
        // The tooltip, which is also the accessibility label, names both.
        let lines = both.help.split(separator: "\n").map(String.init)
        #expect(lines == [
            String(localized: TmuxTabRowMark.Reason.droppedOutput.text),
            String(localized: TmuxTabRowMark.Reason.windowLargerThanTab.text)
        ])
    }

    /// The mark must be readable without its color.
    @Test func everyReason_hasItsOwnSymbolAndText() {
        let reasons = TmuxTabRowMark.Reason.allCases
        #expect(Set(reasons.map(\.symbol)).count == reasons.count)
        #expect(Set(reasons.map { String(localized: $0.text) }).count == reasons.count)
        #expect(reasons.filter { !$0.isWarning } == [.connecting])
    }

    /// The row speaks of a connection state in the words the card over the
    /// panes uses for its title.
    @Test(arguments: [TmuxTabConnection.connecting, .disconnected, .unreachable, .serverReplaced])
    func connectionText_matchesTheCardTitle(connection: TmuxTabConnection) throws {
        let mark = try #require(TmuxTabRowMark.make(connection: connection, hasMirror: true, issues: nil))
        let card = try #require(TmuxConnectionCardContent.make(
            connection: connection,
            hasMirror: true,
            canReconnect: false,
            sessionName: "t"
        ))
        #expect(mark.help == String(localized: card.title))
    }
}
