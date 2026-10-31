// ApprovalRequestText.swift
// Weir — what a request is about, in the words the Needs Attention list and the sidebar show.

import Foundation
import WeirDomain

/// What Weir shows of a request beside its state: the command an
/// approval waits on, or the start of a question. The Needs Attention list
/// and the sidebar's second line read it the same way, and an empty field
/// from the agent counts as missing, so no line ends at its colon.
struct ApprovalRequestText: Equatable {
    /// The command, or the tool's own summary of what it will do.
    let summary: String?
    /// The first question's text, for a question.
    let question: String?
    let toolName: String
    /// `summary` is the input's `command` rather than its `description`
    /// (`ApprovalPresentation.hasInputCommand`).
    let isSummaryCommand: Bool

    init(summary: String?, question: String?, toolName: String, isSummaryCommand: Bool = false) {
        self.summary = summary.flatMap { $0.isEmpty ? nil : $0 }
        self.question = question.flatMap { $0.isEmpty ? nil : $0 }
        self.toolName = toolName
        self.isSummaryCommand = isSummaryCommand
    }

    init(_ request: ApprovalPresentation) {
        self.init(
            summary: request.summary,
            question: request.questions.first?.prompt,
            toolName: request.toolName,
            isSummaryCommand: request.hasInputCommand
        )
    }

    /// What an approval waits on: its command, else the tool.
    var approvalText: String {
        summary ?? toolName
    }

    /// What a question asks: its text, else the tool's summary.
    var questionText: String? {
        question ?? summary
    }

    /// Whether `approvalText` is a command to run, which the sidebar sets in
    /// a command's monospaced face: the input's own `command`, not the
    /// `description` a summary falls back to, and not a bare tool name. A
    /// file change is never one, though Codex's patch can arrive as its
    /// `command`: what it holds is the patch, not something to run.
    var isCommand: Bool {
        summary != nil && isSummaryCommand && !isFileChange
    }

    /// What the request's tool does, which the decision bar and the card
    /// word differently: change files (Claude's editing tools and
    /// Codex's patch), run a command, or anything else.
    var action: PromptApproval.Action {
        AgentTools.action(of: toolName)
    }

    /// Whether the request asks to change files rather than run a command.
    var isFileChange: Bool {
        action == .fileChange
    }
}
