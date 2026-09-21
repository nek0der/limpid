// TmuxConnectionCardContentTests.swift
// Limpid — which card a mirror tab shows for each connection state, and what it says in en and ja.

import Foundation
import Testing
@testable import Limpid

@Suite("TmuxConnectionCardContent")
struct TmuxConnectionCardContentTests {
    private func card(
        _ connection: TmuxTabConnection?,
        hasMirror: Bool = true,
        canReconnect: Bool = true,
        tmuxSupport: AgentTmuxSupport = .supported(binary: "/opt/homebrew/bin/tmux", version: TmuxMirrorTarget.minimumVersion)
    ) -> TmuxConnectionCardContent? {
        TmuxConnectionCardContent.make(
            connection: connection,
            hasMirror: hasMirror,
            canReconnect: canReconnect,
            tmuxSupport: tmuxSupport,
            sessionName: "work"
        )
    }

    private func resolved(_ resource: LocalizedStringResource?, in identifier: String) -> String? {
        guard var resource else { return nil }
        resource.locale = Locale(identifier: identifier)
        return String(localized: resource)
    }

    @Test func make_live_showsNoCard() {
        #expect(card(.live) == nil)
        #expect(card(.live, hasMirror: false) == nil)
    }

    @Test func make_noRecordWithMirror_showsNoCard() {
        #expect(card(nil, hasMirror: true) == nil)
    }

    @Test func make_noRecordWithoutMirror_readsAsDisconnected() {
        let content = card(nil, hasMirror: false)
        #expect(content?.state == .disconnected)
        #expect(content?.actions == [.closeTab, .reconnect])
    }

    @Test func make_connecting_showsProgressWithoutActions() throws {
        let content = try #require(card(.connecting))
        #expect(content.state == .connecting)
        #expect(content.showsProgress)
        #expect(content.message == nil)
        #expect(content.actions.isEmpty)
    }

    @Test func make_disconnected_offersReconnectAsTheEmphasizedAction() throws {
        let content = try #require(card(.disconnected))
        #expect(content.state == .disconnected)
        #expect(!content.showsProgress)
        #expect(content.actions == [.closeTab, .reconnect])
        #expect(content.primaryAction == .reconnect)
    }

    @Test func make_unreachable_offersReconnectAsTheEmphasizedAction() throws {
        let content = try #require(card(.unreachable))
        #expect(content.state == .unreachable)
        #expect(content.actions == [.closeTab, .reconnect])
        #expect(content.primaryAction == .reconnect)
    }

    /// Closing a tab happens with no confirmation, so a card that can only
    /// close must not emphasize the button that does it.
    @Test(arguments: [TmuxTabConnection.disconnected, .unreachable])
    func make_cannotReconnect_offersOnlyCloseAndEmphasizesNothing(connection: TmuxTabConnection) throws {
        let content = try #require(card(connection, canReconnect: false))
        #expect(content.actions == [.closeTab])
        #expect(content.primaryAction == nil)
    }

    @Test(arguments: [true, false])
    func make_serverReplaced_neverOffersReconnect(canReconnect: Bool) throws {
        let content = try #require(card(.serverReplaced, canReconnect: canReconnect))
        #expect(content.state == .serverReplaced)
        #expect(content.actions == [.closeTab])
        #expect(content.primaryAction == nil)
    }

    // MARK: - A Mac with no tmux to reconnect with

    @Test(arguments: [TmuxTabConnection.disconnected, .unreachable])
    func make_withoutTmux_saysSoInsteadOfOfferingAClose(connection: TmuxTabConnection) throws {
        let content = try #require(card(connection, canReconnect: false, tmuxSupport: .notInstalled))
        #expect(content.state == .tmuxUnavailable(.notInstalled))
        #expect(content.actions == [.closeTab])
        #expect(content.primaryAction == nil)
        #expect(resolved(content.title, in: "en") == "Can't reconnect without tmux")
        #expect(
            resolved(content.message, in: "en")
                == "No tmux found. Reconnecting needs tmux \(TmuxMirrorTarget.minimumVersion.description) or newer."
        )
    }

    @Test func make_withTmuxTooOld_namesTheVersionFound() throws {
        let version = try #require(TmuxProtocol.parseVersion("3.2a"))
        let content = try #require(card(.disconnected, tmuxSupport: .unsupported(binary: "/usr/bin/tmux", version: version)))
        #expect(content.state == .tmuxUnavailable(.unsupported(version: version)))
        #expect(resolved(content.title, in: "en") == "This tmux is too old to reconnect")
        #expect(resolved(content.title, in: "ja") == "tmux が古いため再接続できません")
        #expect(
            resolved(content.message, in: "en")
                == "The tmux found is version 3.2a. Reconnecting needs \(TmuxMirrorTarget.minimumVersion.description) or newer."
        )
        #expect(
            resolved(content.message, in: "ja")
                == "見つかった tmux のバージョンは 3.2a です。再接続するには \(TmuxMirrorTarget.minimumVersion.description) 以降が必要です。"
        )
    }

    @Test func make_withAnUnreadableTmuxVersion_saysThat() throws {
        let content = try #require(card(.disconnected, tmuxSupport: .unreadableVersion(binary: "/usr/bin/tmux")))
        #expect(content.state == .tmuxUnavailable(.unreadableVersion))
        #expect(resolved(content.title, in: "en") == "Can't reconnect with this tmux")
        #expect(resolved(content.message, in: "en")?.hasPrefix("Limpid couldn't read the version") == true)
    }

    /// The probe answers a moment after launch. Until it does, the card must
    /// not blame tmux for a tab that is about to reconnect on its own.
    @Test func make_whileTheProbeIsPending_readsAsAnOrdinaryDisconnection() throws {
        let content = try #require(card(.disconnected, tmuxSupport: .pending))
        #expect(content.state == .disconnected)
    }

    /// Only a tab that could otherwise be brought back speaks of tmux: a tab
    /// whose server was replaced has nothing to reconnect to either way.
    @Test func make_serverReplaced_withoutTmux_keepsItsOwnCard() {
        #expect(card(.serverReplaced, tmuxSupport: .notInstalled)?.state == .serverReplaced)
        #expect(card(.connecting, tmuxSupport: .notInstalled)?.state == .connecting)
    }

    @Test func make_texts_resolveInEnglish() throws {
        #expect(resolved(card(.connecting)?.title, in: "en") == "Connecting to tmux…")
        let disconnected = try #require(card(.disconnected))
        #expect(resolved(disconnected.title, in: "en") == "Disconnected from tmux")
        #expect(resolved(disconnected.message, in: "en") == "The session “work” may still be running.")
        #expect(resolved(card(.unreachable)?.title, in: "en") == "Can't reach the tmux server")
        #expect(resolved(card(.serverReplaced)?.title, in: "en") == "This tab can't reconnect")
    }

    @Test func make_texts_resolveInJapanese() throws {
        #expect(resolved(card(.connecting)?.title, in: "ja") == "tmux に接続しています…")
        let disconnected = try #require(card(.disconnected))
        #expect(resolved(disconnected.title, in: "ja") == "tmux から切断されました")
        #expect(resolved(disconnected.message, in: "ja") == "セッション「work」は動き続けている可能性があります。")
        let unreachable = try #require(card(.unreachable))
        #expect(resolved(unreachable.title, in: "ja") == "tmux サーバーに接続できません")
        #expect(resolved(unreachable.message, in: "ja") == "サーバーが応答しないか、ソケットを開けません。再接続してもう一度お試しください。")
        let replaced = try #require(card(.serverReplaced))
        #expect(resolved(replaced.title, in: "ja") == "このタブは再接続できません")
        #expect(
            resolved(replaced.message, in: "ja")
                == "このタブが表示していた tmux サーバーではなくなりました。表示されていた内容は、読み返せるようにそのまま残ります。"
        )
    }

    /// The banner announces this when a reconnect succeeds and it goes away.
    @Test func connectedAnnouncement_resolvesInBothLanguages() {
        let connected: LocalizedStringResource = "Connected to tmux"
        #expect(resolved(connected, in: "en") == "Connected to tmux")
        #expect(resolved(connected, in: "ja") == "tmux に接続しました")
    }

    @Test func buttonTitles_resolveInJapanese() {
        let reconnect: LocalizedStringResource = "Reconnect"
        let closeTab: LocalizedStringResource = "Close Tab"
        #expect(resolved(reconnect, in: "ja") == "再接続")
        #expect(resolved(closeTab, in: "ja") == "タブを閉じる")
    }

    @Test func unavailablePane_textsResolveInJapanese() {
        #expect(resolved(UnavailablePaneCardContent.title, in: "ja") == "このペインは表示できません")
        #expect(
            resolved(UnavailablePaneCardContent.message, in: "ja")
                == "このバージョンの Limpid では読めない形式で保存されているため、このペインでは何も実行されません。"
        )
    }
}

/// The vocabulary the tab row's mark and the pane banner both read, so a
/// state cannot come out as one symbol in one place and another elsewhere.
@Suite("TmuxStatePresentation")
struct TmuxStatePresentationTests {
    /// Every state, including one of each reason a tmux can be unusable.
    private static let all: [TmuxStatePresentation] = [
        .connecting,
        .disconnected,
        .unreachable,
        .serverReplaced,
        .tmuxUnavailable(.notInstalled),
        .droppedOutput,
        .windowLargerThanTab,
        .mirroring(windowName: "editor")
    ]

    /// Swift Testing destructures pairs, so the expectation travels as one
    /// value per state.
    struct Treatment: Sendable {
        let symbol: String
        let severity: TmuxStatePresentation.Severity
    }

    @Test(arguments: [
        (TmuxStatePresentation.connecting, Treatment(symbol: "arrow.triangle.2.circlepath", severity: .neutral)),
        (.disconnected, Treatment(symbol: "cable.connector.slash", severity: .warning)),
        (.unreachable, Treatment(symbol: "exclamationmark.triangle", severity: .warning)),
        (.serverReplaced, Treatment(symbol: "clock.arrow.circlepath", severity: .ended)),
        (.tmuxUnavailable(.notInstalled), Treatment(symbol: "questionmark.circle", severity: .warning)),
        (.tmuxUnavailable(.unreadableVersion), Treatment(symbol: "questionmark.circle", severity: .warning)),
        (.droppedOutput, Treatment(symbol: "exclamationmark.arrow.circlepath", severity: .warning)),
        (.windowLargerThanTab, Treatment(symbol: "crop", severity: .warning)),
        (.mirroring(windowName: "editor"), Treatment(symbol: "rectangle.on.rectangle", severity: .neutral))
    ])
    func state_hasItsSymbolAndSeverity(state: TmuxStatePresentation, treatment: Treatment) {
        #expect(state.symbol == treatment.symbol)
        #expect(state.severity == treatment.severity)
    }

    /// The mark must be readable without its color, so no two states may
    /// share a symbol or a title.
    @Test func everyState_hasItsOwnSymbolAndTitle() {
        #expect(Set(Self.all.map(\.symbol)).count == Self.all.count)
        #expect(Set(Self.all.map { String(localized: $0.title) }).count == Self.all.count)
    }

    /// The three answers stay apart: a Mac with an old tmux must not be told
    /// it has none.
    @Test func unavailableTmux_namesWhichAnswerItWas() throws {
        let version = try #require(TmuxProtocol.parseVersion("3.2a"))
        let titles = [
            TmuxStatePresentation.UnavailableTmux.notInstalled,
            .unreadableVersion,
            .unsupported(version: version)
        ].map { String(localized: TmuxStatePresentation.tmuxUnavailable($0).title) }
        #expect(Set(titles).count == titles.count)
    }

    @Test(arguments: [
        (AgentTmuxSupport.pending, nil as TmuxStatePresentation.UnavailableTmux?),
        (.supported(binary: "/opt/homebrew/bin/tmux", version: TmuxMirrorTarget.minimumVersion), nil),
        (.notInstalled, .notInstalled),
        (.unreadableVersion(binary: "/usr/bin/tmux"), .unreadableVersion)
    ])
    func unavailableTmux_readsTheProbesAnswer(
        support: AgentTmuxSupport,
        expected: TmuxStatePresentation.UnavailableTmux?
    ) {
        #expect(TmuxStatePresentation.UnavailableTmux(support) == expected)
    }

    @Test func unavailableTmux_carriesTheVersionFound() throws {
        let version = try #require(TmuxProtocol.parseVersion("3.2a"))
        let support = AgentTmuxSupport.unsupported(binary: "/usr/bin/tmux", version: version)
        #expect(TmuxStatePresentation.UnavailableTmux(support) == .unsupported(version: version))
    }
}
