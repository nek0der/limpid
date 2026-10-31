// AgentProjectionCommandTests.swift
// Weir — the commands the Rust rules send, decoded in the shapes Rust writes them.

import Foundation
import Testing
@testable import Weir

@Suite("Agent projection command")
struct AgentProjectionCommandTests {
    private static func decode(_ json: String) throws -> AgentProjectionCommand {
        try JSONDecoder().decode(AgentProjectionCommand.self, from: Data(json.utf8))
    }

    @Test func deleteTurn_namesTheTurnInItsOpAndItsTarget() throws {
        // The shape `weir-agent-model` pins in
        // `delete_turn_names_the_turn_in_its_op_and_its_target`.
        let command = try Self.decode("""
        {"op":{"op":"deleteTurn","turnId":"TURN"},
         "target":{"target":"turn","provider":"claude","turnId":"TURN"},
         "expect":{"expect":"none"},"onMismatch":"abort"}
        """)

        guard case let .deleteTurn(turnID) = command.op else {
            Issue.record("decoded as \(command.op)")
            return
        }
        #expect(turnID == "TURN")
        #expect(command.target == .turn(provider: "claude", turnID: "TURN"))
    }

    @Test func endStoppedTurn_namesTheTurnAndItsRecord() throws {
        // This is the shape `weir-agent-model` pins in
        // `end_stopped_turn_names_the_turn_and_its_record`.
        let command = try Self.decode("""
        {"op":{"op":"endStoppedTurn","episodeToken":"5","turnId":"TURN","transcriptPath":"/t/session.jsonl"},
         "target":{"target":"record","provider":"claude","storageId":"RUN"},
         "expect":{"expect":"none"},"onMismatch":"abort"}
        """)

        guard case let .endStoppedTurn(token, turnID, transcriptPath, byProgramStatus) = command.op else {
            Issue.record("decoded as \(command.op)")
            return
        }
        #expect(token == "5")
        #expect(turnID == "TURN")
        #expect(transcriptPath == "/t/session.jsonl")
        #expect(!byProgramStatus, "Rust leaves the key out when the transcript said so")
        #expect(command.target == .record(provider: "claude", storageID: "RUN"))
    }

    @Test func endStoppedTurn_saysWhenTheAgentsOwnReportShowedItStopped() throws {
        let command = try Self.decode("""
        {"op":{"op":"endStoppedTurn","episodeToken":"5","transcriptPath":"/t/session.jsonl","byProgramStatus":true},
         "target":{"target":"record","provider":"claude","storageId":"RUN"},
         "expect":{"expect":"none"},"onMismatch":"abort"}
        """)

        guard case let .endStoppedTurn(_, _, _, byProgramStatus) = command.op else {
            Issue.record("decoded as \(command.op)")
            return
        }
        #expect(byProgramStatus)
    }

    @Test func aTurnTarget_isReportedUnderItsOwnName() throws {
        let data = try JSONEncoder().encode(AgentCommandTarget.turn(provider: "codex", turnID: "TURN"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["target": "turn", "provider": "codex", "turnId": "TURN"])
        let back = try JSONDecoder().decode(AgentCommandTarget.self, from: data)
        #expect(back == .turn(provider: "codex", turnID: "TURN"))
    }
}
