// FinishedNotificationBodyTests.swift
// Limpid — a finished turn's notification leads with its receipt.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Finished notification body")
struct FinishedNotificationBodyTests {
    private typealias Fixture = TurnSummaryFixture

    private static func payload(body: String?) throws -> AgentNotifyPayload {
        let json = """
        {"provider":"claude","kind":"finished","tab":"\(UUID().uuidString)","pane":"\(UUID().uuidString)",
         "runtimeId":"claude:run","body":\(body.map { "\"\($0)\"" } ?? "null"),"presentsBanner":true,
         "suppressWhenPaneFocused":true,"episodeToken":"1","eventToken":"1","state":"finished"}
        """
        return try JSONDecoder().decode(AgentNotifyPayload.self, from: Data(json.utf8))
    }

    private static func runtime(currentTurn: String?) -> AgentRuntimePresentation {
        var runtime = AgentRuntimePresentation.test(badge: AgentBadge(state: .finished, updatedAt: Date()), paneIDs: [UUID()])
        runtime.conversation = Fixture.conversation
        runtime.currentTurnID = currentTurn.map(TurnID.init)
        return runtime
    }

    @Test func theRunsEndedTurn_leadsWithItsReceipt_aboveThePrompt() throws {
        let history = try [Fixture.conversation: [Fixture.turn("T7", changes: Fixture.changedFiles, number: 7)]]

        let body = try AppState.finishedBody(
            Self.payload(body: "Add the tests"),
            runtimes: [Self.runtime(currentTurn: "T7")],
            history: history,
            locale: Locale(identifier: "en")
        )

        #expect(body == "T7 · 2 files +3 −1\nAdd the tests")
    }

    @Test func aTurnTheHarnessPrompted_isWordedByItsKind_underTheReceipt() throws {
        let turn = try Fixture.turn(
            "T7",
            number: 7,
            extras: .init(promptHead: "<task-notification> <task-id>bmtysm2i6</task-id>", promptKind: .backgroundTask)
        )
        let history = [Fixture.conversation: [turn]]

        // The projection quotes no prompt the harness wrote.
        for (locale, expected) in [
            ("en", "T7 · No file changes\nBackground work done"),
            ("ja", "T7 · ファイルの変更なし\nバックグラウンド作業の完了")
        ] {
            #expect(try AppState.finishedBody(
                Self.payload(body: nil),
                runtimes: [Self.runtime(currentTurn: "T7")],
                history: history,
                locale: Locale(identifier: locale)
            ) == expected)
        }
    }

    @Test func aTurnNotEndedYet_orUnknown_leavesTheBodyAsItWas() throws {
        let running = try [Fixture.conversation: [
            Fixture.turn("T7", phase: "started", changes: #"{"kind":"pending"}"#, number: 7)
        ]]

        #expect(try AppState.finishedBody(
            Self.payload(body: "Add the tests"),
            runtimes: [Self.runtime(currentTurn: "T7")],
            history: running,
            locale: Locale(identifier: "en")
        ) == "Add the tests")
        #expect(try AppState.finishedBody(
            Self.payload(body: nil),
            runtimes: [Self.runtime(currentTurn: nil)],
            history: running,
            locale: Locale(identifier: "en")
        ) == nil)
    }
}
