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
        canReconnect: Bool = true
    ) -> TmuxConnectionCardContent? {
        TmuxConnectionCardContent.make(
            connection: connection,
            hasMirror: hasMirror,
            canReconnect: canReconnect,
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
        #expect(content?.kind == .disconnected)
        #expect(content?.actions == [.closeTab, .reconnect])
    }

    @Test func make_connecting_showsProgressWithoutActions() throws {
        let content = try #require(card(.connecting))
        #expect(content.kind == .connecting)
        #expect(content.showsProgress)
        #expect(content.message == nil)
        #expect(content.actions.isEmpty)
    }

    @Test func make_disconnected_offersReconnectAsDefault() throws {
        let content = try #require(card(.disconnected))
        #expect(content.kind == .disconnected)
        #expect(!content.showsProgress)
        #expect(content.actions == [.closeTab, .reconnect])
    }

    @Test func make_unreachable_offersReconnectAsDefault() throws {
        let content = try #require(card(.unreachable))
        #expect(content.kind == .unreachable)
        #expect(content.actions == [.closeTab, .reconnect])
    }

    @Test(arguments: [TmuxTabConnection.disconnected, .unreachable])
    func make_cannotReconnect_offersOnlyClose(connection: TmuxTabConnection) {
        #expect(card(connection, canReconnect: false)?.actions == [.closeTab])
    }

    @Test(arguments: [true, false])
    func make_serverReplaced_neverOffersReconnect(canReconnect: Bool) throws {
        let content = try #require(card(.serverReplaced, canReconnect: canReconnect))
        #expect(content.kind == .serverReplaced)
        #expect(content.actions == [.closeTab])
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
        #expect(resolved(unreachable.message, in: "ja") == "サーバーを起動し直してから再接続してください。")
        let replaced = try #require(card(.serverReplaced))
        #expect(resolved(replaced.title, in: "ja") == "このタブは再接続できません")
        #expect(
            resolved(replaced.message, in: "ja")
                == "このタブが表示していた tmux サーバーではなくなりました。表示されていた内容は読むためにここに残ります。"
        )
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
