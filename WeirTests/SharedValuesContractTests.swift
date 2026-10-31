// SharedValuesContractTests.swift
// Weir — the values the app and the Rust crates each define, checked against the one file both read.
//
// `rust/fixtures/contract/shared-values.json` is also read by the bridge's
// `contract_tests`, so a value changed on one side fails that side's tests
// until the file, and with it the other side, changes too.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.disabled(if: !RepoFixture.hasLocalRepo, "the shared fixtures are in the source tree"))
struct SharedValuesContractTests {
    struct SharedValues: Decodable {
        let maximumDecisionBytes: Int
        let maximumProjectionInputBytes: Int
        let worktreeRoutingFileName: String
        let paneIdentifierVariable: String
        let atWorkStates: [String]
        let notAtWorkStates: [String]
    }

    private static func sharedValues() throws -> SharedValues {
        let root = try #require(RepoFixture.weirRoot)
        let data = try Data(contentsOf: root.appendingPathComponent("rust/fixtures/contract/shared-values.json"))
        return try JSONDecoder().decode(SharedValues.self, from: data)
    }

    @Test func theLimits_areTheOnesTheBrokerAndTheBridgeEnforce() throws {
        let shared = try Self.sharedValues()
        #expect(ApprovalResolution.maximumEncodedBytes == shared.maximumDecisionBytes)
        #expect(AgentProjectionAdapter.inputLimitBytes == shared.maximumProjectionInputBytes)
    }

    @Test func theNames_areTheOnesTheHookReads() throws {
        let shared = try Self.sharedValues()
        #expect(WorktreeRouting.fileName == shared.worktreeRoutingFileName)
        #expect(PaneShellEnvironment.paneIDVariable == shared.paneIdentifierVariable)
        let env = PaneShellEnvironment.variables(
            paneID: UUID(),
            shimDirectories: [],
            zdotdir: nil,
            basePath: "/usr/bin"
        )
        #expect(env[shared.paneIdentifierVariable] != nil)
    }

    @Test func theMidTurnStates_areTheOnesTheHookCountsAsAtWork() throws {
        let shared = try Self.sharedValues()
        let atWork = try shared.atWorkStates.map { try #require(AgentState(rawValue: $0), "\($0)") }
        let notAtWork = try shared.notAtWorkStates.map { try #require(AgentState(rawValue: $0), "\($0)") }
        for state in atWork {
            #expect(state.isMidTurn, "\(state)")
        }
        for state in notAtWork {
            #expect(!state.isMidTurn, "\(state)")
        }
        // Every state this build knows is on one side or the other, so a new
        // one has to be placed in the file before either side can ship it.
        #expect(Set(atWork + notAtWork) == Set(AgentState.allCases))
    }
}
