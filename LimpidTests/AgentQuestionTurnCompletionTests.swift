// AgentQuestionTurnCompletionTests.swift
// Limpid — request ownership across missed projections and delayed startup.

import Darwin
import Foundation
import Testing
@testable import Limpid

struct AgentQuestionTurnCompletionTests {
    private func payload(
        _ event: String, session: String = "session", prompt: String = "prompt",
        agentID: String? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "hook_event_name": event, "session_id": session, "prompt_id": prompt,
            "tool_name": "AskUserQuestion", "tool_input": ["questions": [["question": "Which color?"]]]
        ]
        object["agent_id"] = agentID
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func environment(_ directory: URL) -> [String: String] {
        ["LIMPID_AGENT_STATES_DIR": directory.path]
    }

    @Test func anEarlierQuestionResultCannotCompleteAnotherQuestion() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            let first = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 10, bootSessionID: "boot"
            ))
            let second = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 20, bootSessionID: "boot"
            ))
            try AgentQuestionTurnCompletion.record(
                payload: payload("PostToolUse"), environment: environment,
                completedAt: 30, bootSessionID: "boot"
            )
            #expect(!first.hasCompleted())
            #expect(!second.hasCompleted())
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment,
                completedAt: 40, bootSessionID: "boot"
            )
            #expect(first.hasCompleted())
            #expect(second.hasCompleted())
        }
    }

    @Test func aPreviousStopCannotReleaseAQuestionAfterContinuation() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment,
                completedAt: 10, bootSessionID: "boot"
            )
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 20, bootSessionID: "boot"
            ))
            #expect(!monitor.hasCompleted())
            try AgentQuestionTurnCompletion.record(
                payload: payload("StopFailure"), environment: environment,
                completedAt: 30, bootSessionID: "boot"
            )
            #expect(monitor.hasCompleted())
        }
    }

    @Test func completionBeforeXPCStartupStillReleasesTheOriginalRequest() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment,
                completedAt: 20, bootSessionID: "boot"
            )
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 10, bootSessionID: "boot"
            ))
            #expect(monitor.hasCompleted())
        }
    }

    @Test func defaultStartTimePrecedesInitializationDelay() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            try AgentQuestionTurnCompletion.record(payload: payload("Stop"), environment: environment)
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment
            ))
            #expect(monitor.hasCompleted())
        }
    }

    @Test func otherSessionsPromptsAndSubagentsDoNotCompleteTheRequest() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 10, bootSessionID: "boot"
            ))
            for event in try [
                payload("Stop", session: "another"),
                payload("Stop", prompt: "another"),
                payload("Stop", agentID: "subagent")
            ] {
                try AgentQuestionTurnCompletion.record(
                    payload: event, environment: environment, completedAt: 20, bootSessionID: "boot"
                )
            }
            #expect(!monitor.hasCompleted())
        }
    }

    @Test func aSubagentQuestionWaitsForItsOwnCompletionAcrossRootPrompts() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest", agentID: "child"), environment: environment,
                requestedAt: 10, bootSessionID: "boot"
            ))
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment, completedAt: 20, bootSessionID: "boot"
            )
            #expect(!monitor.hasCompleted())
            try AgentQuestionTurnCompletion.record(
                payload: payload("SubagentStop", agentID: "another"), environment: environment,
                completedAt: 30, bootSessionID: "boot"
            )
            #expect(!monitor.hasCompleted())
            try AgentQuestionTurnCompletion.record(
                payload: payload("SubagentStop", session: "another", agentID: "child"), environment: environment,
                completedAt: 40, bootSessionID: "boot"
            )
            #expect(!monitor.hasCompleted())
            try AgentQuestionTurnCompletion.record(
                payload: payload("SubagentStop", prompt: "next-root-prompt", agentID: "child"), environment: environment,
                completedAt: 50, bootSessionID: "boot"
            )
            #expect(monitor.hasCompleted())
        }
    }

    @Test func anOlderWriterCannotReplaceNewerCompletionEvidence() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 20, bootSessionID: "boot"
            ))
            for completedAt: UInt64 in [30, 10] {
                try AgentQuestionTurnCompletion.record(
                    payload: payload("Stop"), environment: environment,
                    completedAt: completedAt, bootSessionID: "boot"
                )
            }
            #expect(monitor.hasCompleted())
        }
    }

    @Test func receiptsFromAnEarlierBootCannotReleaseAQuestion() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment,
                completedAt: 100, bootSessionID: "old-boot"
            )
            let monitor = try #require(AgentQuestionTurnCompletion(
                payload: payload("PermissionRequest"), environment: environment,
                requestedAt: 10, bootSessionID: "new-boot"
            ))
            #expect(!monitor.hasCompleted())
        }
    }

    @Test func expiredReceiptsArePrunedWithoutRemovingTheNewReceipt() throws {
        try withTempDir { directory in
            let environment = environment(directory)
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop", prompt: "old"), environment: environment,
                completedAt: 1, bootSessionID: "boot"
            )
            var timebase = mach_timebase_info_data_t()
            #expect(mach_timebase_info(&timebase) == KERN_SUCCESS)
            let day = UInt64(86401 * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
            try AgentQuestionTurnCompletion.record(
                payload: payload("Stop"), environment: environment,
                completedAt: day + 1, bootSessionID: "boot"
            )
            let receipts = try FileManager.default.contentsOfDirectory(
                at: directory.appendingPathComponent("question-turns"), includingPropertiesForKeys: nil
            )
            #expect(receipts.filter { $0.pathExtension == "json" }.count == 1)
        }
    }

    @Test func missingIdentityOrStateDirectoryDoesNotEnableMonitoring() throws {
        #expect(try AgentQuestionTurnCompletion(payload: payload("PermissionRequest"), environment: [:]) == nil)
        #expect(try AgentQuestionTurnCompletion(
            payload: payload("PermissionRequest", prompt: ""), environment: ["LIMPID_AGENT_STATES_DIR": "/unused"]
        ) == nil)
    }
}
