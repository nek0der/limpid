// PromptWait.swift
// Limpid — what a wait at the agent's own prompt asks of the person, from what its run recorded.

import Foundation

/// What a run's record says its wait is (`waitKind`), when it says: the
/// provider's permission request, or its own question tool. Records from
/// before the field leave it out, and a kind this build does not know reads
/// as none.
enum PromptWaitKind: String, Codable, Sendable {
    case approval
    case question
}

/// A wait at the agent's prompt that Limpid's approval service does not
/// hold: an ad-hoc-signed build has no service, and some requests never go
/// through it. The run's record says which wait it is and the tool it waits
/// to use (`PromptWaitKind`, `tool`), and its words say what for. A record
/// from before those fields has only the words: the hook records a tool's
/// wait as "Tool: argument" (or the tool alone), so that shape is read as an
/// approval, and anything else as a wait we cannot name.
///
/// Built once, where the attention list builds the item
/// (`AttentionQueueReducer`), and for a notification from the same record,
/// so the decision bar, the sidebar, the list, and the banner word one wait
/// the same way: an approval and a question as the requests Limpid holds
/// are worded, and a wait we cannot name in the state's own neutral word
/// ("Needs response").
enum PromptWait: Equatable, Sendable {
    case approval(PromptApproval)
    /// The agent's own question, as its record says; its words, `nil` when
    /// it gave none.
    case question(detail: String?)
    /// A wait we cannot name, from a record that does not say: the agent's
    /// words, `nil` when it said nothing.
    case unclassified(detail: String?)

    /// The wait as the record states it. A question stays one whatever its
    /// words look like; an approval names its tool even when no list here
    /// knows it. With no kind, the words alone decide (`init(detail:)`).
    init(detail: String?, kind: PromptWaitKind?, tool: String?) {
        switch kind {
        case .question:
            self = .question(detail: Self.words(detail).flatMap(Self.questionText))
        case .approval:
            self = .approval(PromptApproval(recorded: Self.words(detail), tool: Self.words(tool)))
        case nil:
            self.init(detail: detail)
        }
    }

    /// The wait read from its words alone, for a record from before it said
    /// what its wait is. The question tool's bare name, which earlier hooks
    /// recorded for a question with no text, still says it is one.
    init(detail: String?) {
        guard let text = Self.words(detail) else {
            self = .unclassified(detail: nil)
            return
        }
        if text == AgentTools.question {
            self = .question(detail: nil)
            return
        }
        self = PromptApproval(text).map(Self.approval) ?? .unclassified(detail: text)
    }

    /// The agent's words in full, for the tooltip that the cut-short line
    /// leaves out.
    var detail: String? {
        switch self {
        case let .approval(approval): approval.detail
        case let .question(detail), let .unclassified(detail): detail
        }
    }

    private static func words(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A question's words, less the tool's own name, which earlier hooks
    /// recorded for a question whose payload had no text.
    private static func questionText(_ text: String) -> String? {
        text == AgentTools.question ? nil : text
    }
}

/// The tool names Limpid tells apart, in one place: the decision bar words
/// a file change and a command differently, for a request Limpid holds
/// (`ApprovalRequestText`) and for one it does not (`PromptApproval`).
enum AgentTools {
    /// Claude's editing tools and Codex's patch.
    static let fileChange: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch"]

    /// Tools that run a command: Claude's shell, and Codex's under the
    /// names its hooks and approvals report.
    static let command: Set<String> = ["Bash", "PowerShell", "exec", "exec_command", "shell", "local_shell", "unified_exec"]

    /// Other tools Claude and Codex ask permission for. Only the words of a
    /// record from before `waitKind` need it: a name outside these lists
    /// counts there only with an MCP server's prefix, since a bare word
    /// before a colon is as likely the start of a question.
    static let other: Set<String> = [
        "Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "Task", "Agent", "Skill", "SlashCommand",
        "NotebookRead", "TodoWrite", "BashOutput", "KillShell", "ExitPlanMode", "web_search", "view_image"
    ]

    /// Claude's question tool.
    static let question = "AskUserQuestion"

    static func action(of tool: String) -> PromptApproval.Action {
        if fileChange.contains(tool) {
            .fileChange
        } else if command.contains(tool) {
            .command
        } else {
            .other
        }
    }

    /// Whether the words name a tool, for a record from before `tool`.
    static func isKnown(_ name: String) -> Bool {
        fileChange.contains(name) || command.contains(name) || other.contains(name)
            || (name.hasPrefix("mcp__") && !name.contains(where: \.isWhitespace))
    }
}

/// A tool's request at the agent's prompt.
struct PromptApproval: Equatable, Sendable {
    /// What the tool does, which the decision bar words differently.
    enum Action: Equatable, Sendable {
        case fileChange
        case command
        case other
    }

    /// `nil` when nothing names the tool, as for a request that only says
    /// permission is needed.
    let tool: String?
    let action: Action
    /// The command on one line, or the name of the file (its last path
    /// component, as the line has no room for the folders); `nil` when only
    /// the tool is known.
    let subject: String?
    /// The words as recorded; `nil` when the run recorded none.
    let detail: String?

    /// What "Waiting for approval:" names: the command or file, else the
    /// tool; `nil` when neither is known.
    var fact: String? {
        subject ?? tool
    }

    init(tool: String?, action: Action, subject: String?, detail: String?) {
        self.tool = tool
        self.action = action
        self.subject = subject
        self.detail = detail
    }

    /// An approval the record says it is, of `tool` when it names one. The
    /// words give the argument when they are that tool's ("Bash: swift
    /// test"), else whatever request they read as.
    init(recorded text: String?, tool: String?) {
        if let tool {
            let action = AgentTools.action(of: tool)
            let argument = text.flatMap { text in
                text.hasPrefix(tool + ": ") ? String(text.dropFirst(tool.count + 2)) : nil
            }.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            self.init(tool: tool, action: action, subject: argument.map { Self.subject($0, action: action) }, detail: text)
            return
        }
        if let text, let read = Self(text) {
            self = read
            return
        }
        self.init(tool: nil, action: .other, subject: nil, detail: text)
    }

    /// The words, read as a tool's request; `nil` when they are not one.
    init?(_ text: String) {
        if let separator = text.range(of: ": ") {
            let tool = String(text[..<separator.lowerBound])
            let argument = text[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if AgentTools.isKnown(tool), !argument.isEmpty {
                let action = AgentTools.action(of: tool)
                self.init(tool: tool, action: action, subject: Self.subject(argument, action: action), detail: text)
                return
            }
        }
        // The tool alone, as Codex's hook records it, or with nothing after
        // its colon.
        let name = text.hasSuffix(":") ? String(text.dropLast()) : text
        if AgentTools.isKnown(name) {
            self.init(tool: name, action: AgentTools.action(of: name), subject: nil, detail: text)
            return
        }
        guard let message = Self.permissionMessage(text) else { return nil }
        self = message
    }

    /// What a request is about, as short as the row and the banner need it:
    /// a command on one line, a path as its file's name, anything else on
    /// one line. The held request's banner shortens its summary the same way.
    static func subject(_ argument: String, action: Action) -> String {
        let line = argument.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard action != .command else { return line }
        return fileName(argument) ?? line
    }

    /// The last component of a path, whichever separator it uses; `nil`
    /// for words that are not one. A relative path counts only without
    /// spaces, so a sentence with a slash in it is left whole.
    static func fileName(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isNewline), trimmed.contains(where: { $0 == "/" || $0 == "\\" }) else { return nil }
        let isAbsolute = trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.dropFirst().hasPrefix(":\\")
        guard isAbsolute || !trimmed.contains(where: \.isWhitespace) else { return nil }
        return trimmed.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
    }

    /// The provider's own permission message, which the hook records when
    /// no tool event came first ("Claude needs your permission to use
    /// Bash"), or its own placeholder for one with no words ("permission").
    private static func permissionMessage(_ text: String) -> Self? {
        if text == "permission" {
            return Self(tool: nil, action: .other, subject: nil, detail: text)
        }
        guard let range = text.range(of: "needs your permission", options: .caseInsensitive) else { return nil }
        let rest = text[range.upperBound...]
        let tool = rest.range(of: " to use ").map { rest[$0.upperBound...] }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) }
            .flatMap { $0.isEmpty || $0.contains(where: \.isWhitespace) ? nil : $0 }
        return Self(tool: tool, action: tool.map(AgentTools.action(of:)) ?? .other, subject: nil, detail: text)
    }
}
