// ApprovalPresentationFixture.swift
// Limpid — one builder for the approval requests the suites hand a store.

import Foundation
@testable import Limpid

extension ApprovalPresentation {
    /// A pending Claude `Bash` request with fresh ids and ten minutes left,
    /// changed only where a test says.
    ///
    /// The initializer takes every field the broker sends, and suites that
    /// wrote it out in full hid the one or two fields the test was about
    /// among the rest.
    static func test(
        epoch: UUID = UUID(),
        runID: UUID = UUID(),
        requestID: UUID = UUID(),
        provider: AgentKind = .claude,
        sessionID: String? = nil,
        operationID: String? = nil,
        toolName: String = "Bash",
        summary: String? = nil,
        requestDescription: String? = nil,
        inputDescription: String = "{}",
        deadlineMilliseconds: UInt64 = 600_000,
        questions: [ApprovalQuestion] = [],
        command: String? = nil,
        hasInputCommand: Bool = false,
        agentRunID: UUID? = nil
    ) -> ApprovalPresentation {
        ApprovalPresentation(
            epoch: epoch,
            runID: runID,
            requestID: requestID,
            provider: provider,
            sessionID: sessionID,
            operationID: operationID,
            toolName: toolName,
            summary: summary,
            requestDescription: requestDescription,
            inputDescription: inputDescription,
            deadlineMilliseconds: deadlineMilliseconds,
            questions: questions,
            command: command,
            hasInputCommand: hasInputCommand,
            agentRunID: agentRunID
        )
    }
}
