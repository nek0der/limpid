// ApprovalCommandTests.swift
// Limpid — the command an approval request runs, read from its tool input, which a summary may be taken from.

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Limpid

struct ApprovalCommandTests {
    /// Any tool's string `command` is what its summary was taken from; a
    /// description in its place is prose.
    @Test func hasCommand_isAStringCommand_forAnyTool() {
        #expect(ApprovalControllerConnection.hasCommand(input: ["command": "git status"]))
        #expect(!ApprovalControllerConnection.hasCommand(input: ["command": ["git", "status"], "description": "Inspect status"]))
        #expect(!ApprovalControllerConnection.hasCommand(input: ["description": "Explore the code"]))
        #expect(!ApprovalControllerConnection.hasCommand(input: "git status"))
    }

    @Test func command_bashWithAString_isTheCommand() {
        #expect(ApprovalControllerConnection.command(toolName: "Bash", input: ["command": "make test"]) == "make test")
    }

    @Test func command_bashWithoutAString_isNone() {
        #expect(ApprovalControllerConnection.command(toolName: "Bash", input: ["command": ["make", "test"]]) == nil)
        #expect(ApprovalControllerConnection.command(toolName: "Bash", input: ["command": 7]) == nil)
        #expect(ApprovalControllerConnection.command(toolName: "Bash", input: "make test") == nil)
    }

    /// A description is not what runs.
    @Test func command_otherTools_isNone() {
        #expect(ApprovalControllerConnection.command(toolName: "Task", input: ["description": "ls"]) == nil)
        #expect(ApprovalControllerConnection.command(toolName: "Edit", input: ["file_path": "/x", "command": "ls"]) == nil)
        #expect(ApprovalControllerConnection.command(toolName: "shell", input: ["command": ["ls"]]) == nil)
    }
}
