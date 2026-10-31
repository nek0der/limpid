// PromptWaitTests.swift
// Weir — reading a wait at the agent's own prompt as an approval, a question, or one that needs a response.

import Foundation
import Testing
@testable import Weir

struct PromptWaitTests {
    /// The words a run recorded, and the tool and subject read from them.
    struct Shape: Sendable, CustomTestStringConvertible {
        let detail: String
        let tool: String
        let subject: String?

        init(_ detail: String, _ tool: String, _ subject: String?) {
            self.detail = detail
            self.tool = tool
            self.subject = subject
        }

        var testDescription: String {
            detail
        }
    }

    private static func approval(_ detail: String) -> PromptApproval? {
        guard case let .approval(approval) = PromptWait(detail: detail) else { return nil }
        return approval
    }

    @Test(arguments: [
        // Claude's hook: the tool and its file.
        Shape("Write: /Users/me/repo/notes.txt", "Write", "notes.txt"),
        Shape("Edit: /a.txt", "Edit", "a.txt"),
        Shape("MultiEdit: /repo/Sources/App.swift", "MultiEdit", "App.swift"),
        Shape("NotebookEdit: /repo/analysis.ipynb", "NotebookEdit", "analysis.ipynb"),
        // Codex's hook records the tool alone.
        Shape("apply_patch", "apply_patch", nil),
    ] as [Shape])
    func aFileToolsWait_isAFileChange_namedByItsFile(shape: Shape) throws {
        let approval = try #require(Self.approval(shape.detail))
        #expect(approval.action == .fileChange)
        #expect(approval.tool == shape.tool)
        #expect(approval.subject == shape.subject)
        #expect(approval.detail == shape.detail)
    }

    @Test(arguments: [
        Shape("Bash: swift test", "Bash", "swift test"),
        Shape("Bash: git status\n  --short", "Bash", "git status --short"),
        Shape("Bash", "Bash", nil),
        Shape("exec_command: ls -la /tmp", "exec_command", "ls -la /tmp"),
        // Codex's shells, by the names its hook records alone.
        Shape("shell", "shell", nil),
        Shape("local_shell", "local_shell", nil),
        Shape("unified_exec", "unified_exec", nil)
    ] as [Shape])
    func aShellToolsWait_isACommand_onOneLine(shape: Shape) throws {
        let approval = try #require(Self.approval(shape.detail))
        #expect(approval.action == .command)
        #expect(approval.tool == shape.tool)
        #expect(approval.subject == shape.subject)
    }

    @Test(arguments: [
        Shape("Read: /repo/README.md", "Read", "README.md"),
        Shape("WebFetch", "WebFetch", nil),
        Shape("mcp__github__create_issue", "mcp__github__create_issue", nil)
    ] as [Shape])
    func anotherToolsWait_isAnApproval_ofNeitherKind(shape: Shape) throws {
        let approval = try #require(Self.approval(shape.detail))
        #expect(approval.action == .other)
        #expect(approval.tool == shape.tool)
        #expect(approval.subject == shape.subject)
        #expect(approval.fact == shape.subject ?? shape.tool)
    }

    @Test func theProvidersOwnPermissionMessage_isAnApproval() throws {
        let named = try #require(Self.approval("Claude needs your permission to use Bash"))
        #expect(named.tool == "Bash")
        #expect(named.action == .command)
        #expect(named.subject == nil)
        let unnamed = try #require(Self.approval("Claude needs your permission"))
        #expect(unnamed.tool == nil)
        #expect(unnamed.fact == nil)
        // The hook's placeholder for a permission request with no words.
        let placeholder = try #require(Self.approval("permission"))
        #expect(placeholder.action == .other)
        #expect(placeholder.fact == nil)
    }

    @Test(arguments: [
        "Which color?",
        "Note: pick one of the two branches",
        "Allow network access?",
        "Bash is not installed"
    ])
    func wordsThatAreNotAToolsRequest_waitForAnAnswer(detail: String) {
        #expect(PromptWait(detail: detail) == .unclassified(detail: detail))
    }

    @Test(arguments: [nil, "", "  \n "] as [String?])
    func noWords_waitForAnAnswer_withNone(detail: String?) {
        #expect(PromptWait(detail: detail) == .unclassified(detail: nil))
        #expect(PromptWait(detail: detail).detail == nil)
    }

    // MARK: - What the record says

    @Test func aRecordedQuestion_staysOne_whateverItsWordsLookLike() {
        #expect(PromptWait(detail: "Read: which file first?", kind: .question, tool: nil)
            == .question(detail: "Read: which file first?"))
        #expect(PromptWait(detail: "Which color?", kind: .question, tool: "AskUserQuestion")
            == .question(detail: "Which color?"))
    }

    /// Only the agent's status report says a sign-in, and it carries no
    /// words: the wait is the sign-in alone, whatever the record holds.
    @Test func aRecordedSignIn_isOne_withNoWords() {
        let wait = PromptWait(detail: "mcp__docs__search", kind: .signIn, tool: "mcp__docs__search")
        #expect(wait == .signIn)
        #expect(wait.detail == nil)
    }

    @Test func aRecordedApproval_ofAToolNoListKnows_namesTheTool() throws {
        let wait = PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor")
        guard case let .approval(approval) = wait else {
            Issue.record("expected an approval, got \(wait)")
            return
        }
        #expect(approval.tool == "Monitor")
        #expect(approval.action == .other)
        #expect(approval.fact == "Monitor")
        let lsp = try #require(Self.recorded("LSP: hover", tool: "LSP"))
        #expect(lsp.subject == "hover")
    }

    @Test func aRecordedApproval_takesItsArgument_fromItsToolsWords() throws {
        let write = try #require(Self.recorded("Write: /Users/me/repo/notes.txt", tool: "Write"))
        #expect(write.action == .fileChange)
        #expect(write.subject == "notes.txt")
        #expect(write.detail == "Write: /Users/me/repo/notes.txt")
        let bash = try #require(Self.recorded("Bash: swift test\n  --parallel", tool: "Bash"))
        #expect(bash.action == .command)
        #expect(bash.subject == "swift test --parallel")
        let shell = try #require(Self.recorded(nil, tool: "unified_exec"))
        #expect(shell.action == .command)
        #expect(shell.fact == "unified_exec")
        // No tool recorded: the provider's message, read as before.
        let message = try #require(Self.recorded("Claude needs your permission to use Edit", tool: nil))
        #expect(message.tool == "Edit")
        #expect(message.action == .fileChange)
        let bare = try #require(Self.recorded(nil, tool: nil))
        #expect(bare.fact == nil)
    }

    @Test func aRecordWithNoKind_isReadFromItsWords() {
        // A record from before `waitKind`: a question that starts like a
        // tool's request reads as an approval. Kept as it is: such records
        // go once their run ends.
        guard case .approval = PromptWait(detail: "Read: which file first?", kind: nil, tool: nil) else {
            Issue.record("a record with no kind reads a tool's words as an approval")
            return
        }
        #expect(PromptWait(detail: "Read: which file first?", kind: nil, tool: nil)
            == PromptWait(detail: "Read: which file first?"))
    }

    @Test func theQuestionToolsBareName_isNoWords() {
        // Earlier hooks recorded it for a question whose payload had no text.
        #expect(PromptWait(detail: "AskUserQuestion") == .question(detail: nil))
        #expect(PromptWait(detail: "AskUserQuestion", kind: .question, tool: nil) == .question(detail: nil))
    }

    @Test(arguments: [
        ("/Users/me/repo/notes.txt", "notes.txt"),
        ("C:\\repo\\src\\main.rs", "main.rs"),
        ("src/app/main.swift", "main.swift"),
        ("~/My Documents/plan.md", "plan.md"),
        ("notes.txt", "notes.txt"),
        // A sentence with a slash in it is not a path.
        ("fix the a/b handling", "fix the a/b handling")
    ])
    func aPath_isNamedByItsFile_whicheverSeparatorItUses(argument: String, subject: String) {
        #expect(PromptApproval.subject(argument, action: .fileChange) == subject)
    }

    private static func recorded(_ detail: String?, tool: String?) -> PromptApproval? {
        guard case let .approval(approval) = PromptWait(detail: detail, kind: .approval, tool: tool) else { return nil }
        return approval
    }

    @Test func aToolWithNoArgument_afterItsColon_isTheToolAlone() throws {
        // "Write: " with nothing after it is not a file, nor a question.
        let approval = try #require(Self.approval("Write: "))
        #expect(approval.tool == "Write")
        #expect(approval.action == .fileChange)
        #expect(approval.subject == nil)
        #expect(approval.fact == "Write")
    }

    @MainActor
    @Test("the wait a notification announces is read from the badge only while the run waits")
    func waitOf_readsTheBadge_onlyWhileItWaits() {
        var badge = AgentBadge(state: .needsInput, updatedAt: Date())
        badge.detail = "Bash: swift test"
        badge.waitKind = "approval"
        badge.tool = "Bash"
        guard case let .approval(approval)? = AppState.waitOf(badge) else {
            Issue.record("expected the badge's approval")
            return
        }
        #expect(approval.subject == "swift test")

        badge.waitKind = "question"
        badge.detail = "Read: which file first?"
        #expect(AppState.waitOf(badge) == .question(detail: "Read: which file first?"))

        // A record from before the fields: its words decide.
        badge.waitKind = nil
        badge.tool = nil
        badge.detail = "Allow network access?"
        #expect(AppState.waitOf(badge) == .unclassified(detail: "Allow network access?"))

        // A run that moved on describes something else.
        badge.state = .running
        badge.waitKind = "approval"
        #expect(AppState.waitOf(badge) == nil)
    }
}
