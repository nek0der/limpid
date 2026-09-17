// TmuxTabRowMarkTests.swift
// Limpid — checks which mark a mirror tab's row carries for each connection state and warning.

import Foundation
import Testing
@testable import Limpid

struct TmuxTabRowMarkTests {
    /// A tab opened for a hosted agent carries no mark of its own when
    /// nothing is wrong: its identity glyph already shows the tmux dot.
    @Test func liveAgentTab_withNothingToWarnAbout_hasNoMark() {
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: nil, origin: .agent) == nil)
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues(), origin: .agent) == nil)
        // Registered, not yet recorded: the mirror is there and says nothing.
        #expect(TmuxTabRowMark.make(connection: nil, hasMirror: true, issues: nil, origin: .agent) == nil)
    }

    /// A tab the user opened says it is a mirror even when all is well, so
    /// the row does not read as an ordinary terminal.
    @Test func liveUserTab_withNothingToWarnAbout_carriesTheNeutralMark() throws {
        let mark = try #require(TmuxTabRowMark.make(
            connection: .live,
            hasMirror: true,
            issues: TmuxTabIssues(),
            origin: .user,
            windowName: "editor"
        ))
        #expect(mark.reasons == [.mirroring])
        #expect(!mark.primary.isWarning)
        // The tooltip names the window, in whatever language it resolves to.
        #expect(mark.help.contains("editor"))
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
            String(localized: TmuxTabRowMark.Reason.droppedOutput.text(windowName: "")),
            String(localized: TmuxTabRowMark.Reason.windowLargerThanTab.text(windowName: ""))
        ])
    }

    /// The mark must be readable without its color.
    @Test func everyReason_hasItsOwnSymbolAndText() {
        let reasons = TmuxTabRowMark.Reason.allCases
        #expect(Set(reasons.map(\.symbol)).count == reasons.count)
        #expect(Set(reasons.map { String(localized: $0.text(windowName: "w")) }).count == reasons.count)
        #expect(reasons.filter { !$0.isWarning } == [.connecting, .mirroring])
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

    @Test func neutralMarkText_resolvesInBothLanguages() {
        var english = TmuxTabRowMark.Reason.mirroring.text(windowName: "editor")
        english.locale = Locale(identifier: "en")
        #expect(String(localized: english) == "Mirroring the tmux window “editor”")
        var japanese = TmuxTabRowMark.Reason.mirroring.text(windowName: "editor")
        japanese.locale = Locale(identifier: "ja")
        #expect(String(localized: japanese) == "tmux のウィンドウ「editor」を表示しています")
    }
}
