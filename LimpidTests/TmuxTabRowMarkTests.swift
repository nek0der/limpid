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
        #expect(mark.states == [.mirroring(windowName: "editor")])
        #expect(mark.primary.severity == .neutral)
        // The tooltip names the window, in whatever language it resolves to.
        #expect(mark.help.contains("editor"))
    }

    @Test(arguments: [
        (TmuxTabConnection.connecting, TmuxStatePresentation.connecting),
        (.disconnected, .disconnected),
        (.unreachable, .unreachable),
        (.serverReplaced, .serverReplaced)
    ])
    func connectionState_isTheOnlyReason(connection: TmuxTabConnection, state: TmuxStatePresentation) {
        let issues = TmuxTabIssues(hasDroppedOutput: true, isWindowLargerThanTab: true)
        let mark = TmuxTabRowMark.make(connection: connection, hasMirror: true, issues: issues)
        // A tab that is not live repaints and resizes nothing, so its
        // mirror's warnings are left out.
        #expect(mark?.states == [state])
    }

    /// Such a tab was restored or reopened and nothing feeds it yet, which
    /// its card also reads as disconnected.
    @Test func tabWithoutRecordOrMirror_readsAsDisconnected() {
        #expect(TmuxTabRowMark.make(connection: nil, hasMirror: false, issues: nil)?.states == [.disconnected])
    }

    @Test func liveTab_listsEveryWarning_droppedOutputFirst() throws {
        let dropped = TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues(hasDroppedOutput: true))
        #expect(dropped?.states == [.droppedOutput])

        let larger = TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues(isWindowLargerThanTab: true))
        #expect(larger?.states == [.windowLargerThanTab])

        let both = try #require(TmuxTabRowMark.make(
            connection: .live,
            hasMirror: true,
            issues: TmuxTabIssues(hasDroppedOutput: true, isWindowLargerThanTab: true)
        ))
        #expect(both.states == [.droppedOutput, .windowLargerThanTab])
        #expect(both.primary == .droppedOutput)
        // The tooltip, which is also the accessibility label, names both.
        let lines = both.help.split(separator: "\n").map(String.init)
        #expect(lines == [
            String(localized: TmuxStatePresentation.droppedOutput.title),
            String(localized: TmuxStatePresentation.windowLargerThanTab.title)
        ])
    }

    // MARK: - A Mac with no tmux to reconnect with

    /// The row must not say "Disconnected from tmux" while the card over the
    /// panes says the tmux found is too old: that is one state told two ways.
    @Test(arguments: [TmuxTabConnection.disconnected, .unreachable])
    func lostConnection_withoutUsableTmux_saysSo(connection: TmuxTabConnection) throws {
        let version = try #require(TmuxProtocol.parseVersion("3.2a"))
        let support = AgentTmuxSupport.unsupported(binary: "/usr/bin/tmux", version: version)
        let mark = try #require(TmuxTabRowMark.make(
            connection: connection,
            hasMirror: true,
            issues: nil,
            tmuxSupport: support
        ))
        #expect(mark.states == [.tmuxUnavailable(.unsupported(version: version))])
        #expect(mark.help == String(localized: TmuxStatePresentation.tmuxUnavailable(.unsupported(version: version)).title))
    }

    @Test func restoredTabWithoutMirror_withoutTmux_saysSo() {
        let mark = TmuxTabRowMark.make(connection: nil, hasMirror: false, issues: nil, tmuxSupport: .notInstalled)
        #expect(mark?.states == [.tmuxUnavailable(.notInstalled)])
    }

    /// Only a tab that could otherwise be brought back speaks of tmux, as
    /// its card does: a replaced server has nothing to reconnect to either
    /// way, and a connect in flight is about to answer for itself.
    @Test func otherStates_withoutTmux_keepTheirOwnReason() {
        #expect(
            TmuxTabRowMark.make(connection: .serverReplaced, hasMirror: true, issues: nil, tmuxSupport: .notInstalled)?
                .states == [.serverReplaced]
        )
        #expect(
            TmuxTabRowMark.make(connection: .connecting, hasMirror: true, issues: nil, tmuxSupport: .notInstalled)?
                .states == [.connecting]
        )
    }

    /// A pending probe must not make a tab that is about to reconnect blame
    /// tmux for it.
    @Test func lostConnection_whileTheProbeIsPending_readsAsAnOrdinaryDisconnection() {
        #expect(
            TmuxTabRowMark.make(connection: .disconnected, hasMirror: true, issues: nil, tmuxSupport: .pending)?
                .states == [.disconnected]
        )
    }

    /// The row speaks of a connection state in the words the card over the
    /// panes uses for its title, and shows the same symbol for it.
    @Test(arguments: [TmuxTabConnection.connecting, .disconnected, .unreachable, .serverReplaced])
    func connectionText_matchesTheCardTitle(connection: TmuxTabConnection) throws {
        let mark = try #require(TmuxTabRowMark.make(connection: connection, hasMirror: true, issues: nil))
        let card = try #require(TmuxConnectionCardContent.make(
            connection: connection,
            hasMirror: true,
            canReconnect: false,
            sessionName: "t"
        ))
        #expect(mark.primary == card.state)
        #expect(mark.help == String(localized: card.title))
    }

    @Test func neutralMarkText_resolvesInBothLanguages() {
        var english = TmuxStatePresentation.mirroring(windowName: "editor").title
        english.locale = Locale(identifier: "en")
        #expect(String(localized: english) == "Mirroring the tmux window “editor”")
        var japanese = TmuxStatePresentation.mirroring(windowName: "editor").title
        japanese.locale = Locale(identifier: "ja")
        #expect(String(localized: japanese) == "tmux のウィンドウ「editor」を表示しています")
    }
}
