// TmuxTabRowMarkTests.swift
// Limpid — checks which mark a mirror tab's row carries for each connection state and warning.

import Foundation
import Testing
@testable import Limpid

struct TmuxTabRowMarkTests {
    /// Nothing is wrong, so nothing is in the trailing slot. That the tab is
    /// drawn from tmux is said by the badge on its identity glyph instead
    /// (`TmuxTabIdentityBadge`), for both kinds of mirror.
    @Test func liveMirrorTab_withNothingToWarnAbout_hasNoMark() {
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: nil) == nil)
        #expect(TmuxTabRowMark.make(connection: .live, hasMirror: true, issues: TmuxTabIssues()) == nil)
        // Registered, not yet recorded: the mirror is there and says nothing.
        #expect(TmuxTabRowMark.make(connection: nil, hasMirror: true, issues: nil) == nil)
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
}

/// Which tabs wear the badge that says Limpid draws them from tmux, and
/// what it says, apart from the row that composes it onto the glyph.
@Suite("Tab row tmux badge")
struct TmuxTabIdentityBadgeTests {
    /// Both kinds of mirror wear it: the fact it states — this tab is drawn
    /// from tmux and closing it does not stop what it shows — is the same
    /// one either way.
    @Test(arguments: [Tab.MirrorOrigin.user, .agent])
    func mirrorTab_wearsTheBadge(origin: Tab.MirrorOrigin) throws {
        let badge = try #require(TmuxTabIdentityBadge.make(kind: .tmuxMirror, origin: origin))
        #expect(badge.origin == origin)
        #expect(badge.symbol == TmuxStatePresentation.mirroring(windowName: "").symbol)
    }

    /// An ordinary tab wears none, including one whose pane the user put
    /// into tmux by hand: Limpid does not draw that pane, and closing its
    /// tab ends the client rather than leaving a window running (design D5).
    /// Such a pane never makes the tab a mirror, so the kind is all the
    /// badge has to read.
    @Test(arguments: [Tab.MirrorOrigin.user, .agent])
    func terminalTab_wearsNone(origin: Tab.MirrorOrigin) {
        #expect(TmuxTabIdentityBadge.make(kind: .terminal, origin: origin) == nil)
    }

    /// The user's mirror is told about tmux, because the window is theirs
    /// and they opened it from tmux themselves.
    @Test func usersMirror_namesTmux() throws {
        let badge = try #require(TmuxTabIdentityBadge.make(kind: .tmuxMirror, origin: .user))
        var english = badge.help
        english.locale = Locale(identifier: "en")
        #expect(String(localized: english) == "Shown from tmux — the window keeps running when this tab closes")
        var japanese = badge.help
        japanese.locale = Locale(identifier: "ja")
        #expect(String(localized: japanese) == "tmux から表示中。このタブを閉じてもウィンドウは動き続けます")
    }

    /// An agent's user is not told about tmux (design D6): they did not
    /// choose it, and what they need to know reads without it.
    @Test func agentsTab_saysBackgroundRatherThanTmux() throws {
        let badge = try #require(TmuxTabIdentityBadge.make(kind: .tmuxMirror, origin: .agent))
        var english = badge.help
        english.locale = Locale(identifier: "en")
        let text = String(localized: english)
        #expect(text == "Runs in the background — it keeps running when this tab closes")
        #expect(!text.contains("tmux"))
        var japanese = badge.help
        japanese.locale = Locale(identifier: "ja")
        let japaneseText = String(localized: japanese)
        #expect(japaneseText == "バックグラウンドで実行中。このタブを閉じても動き続けます")
        #expect(!japaneseText.contains("tmux"))
    }
}
