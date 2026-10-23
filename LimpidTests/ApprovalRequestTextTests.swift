// ApprovalRequestTextTests.swift
// Limpid — what an approval request's text says it is: a file change by its tool, a command only when its summary is one.

import Foundation
import Testing
@testable import Limpid

struct ApprovalRequestTextTests {
    @Test func fileChanges_areTheEditingTools() {
        #expect(ApprovalRequestText(summary: nil, question: nil, toolName: "Edit").isFileChange)
        #expect(ApprovalRequestText(summary: nil, question: nil, toolName: "apply_patch").isFileChange)
        #expect(!ApprovalRequestText(summary: nil, question: nil, toolName: "Bash").isFileChange)
    }

    @Test func onlyARunsCommand_isACommand() {
        #expect(ApprovalRequestText(summary: "swift test", question: nil, toolName: "Bash", isSummaryCommand: true).isCommand)
        // Codex's shell with its command as a list, and Claude's Task: the
        // summary fell back to the input's description, which is prose.
        #expect(!ApprovalRequestText(summary: "Inspect status", question: nil, toolName: "shell", isSummaryCommand: false).isCommand)
        #expect(!ApprovalRequestText(summary: "Explore the code", question: nil, toolName: "Task", isSummaryCommand: false).isCommand)
        #expect(!ApprovalRequestText(summary: nil, question: nil, toolName: "WebFetch", isSummaryCommand: true).isCommand)
        // Codex's patch, sent as its input's `command`, is a file change.
        #expect(!ApprovalRequestText(summary: "*** Begin Patch", question: nil, toolName: "apply_patch", isSummaryCommand: true).isCommand)

        let request = ApprovalPresentation.test(
            provider: .codex,
            toolName: "shell",
            summary: "Inspect status",
            deadlineMilliseconds: 0
        )
        #expect(!ApprovalRequestText(request).isCommand)
    }
}
