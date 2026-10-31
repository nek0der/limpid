// RequestBannerText.swift
// Weir — the words on a request's banner.

import Foundation
import WeirDomain

/// The title, subtitle, and body of the banner a request posts as it arrives.
enum RequestBannerText {
    struct Words: Equatable {
        let title: String
        /// Nil when the request's pane is unknown, so nothing says where.
        let subtitle: String?
        let body: String
    }

    /// Titled by what is asked ("Claude Code is waiting for approval"), as
    /// every agent banner is, with where the agent works as the
    /// subtitle: both agents set generic terminal titles, so the project or
    /// worktree is what tells two banners apart, but it does not say what
    /// happened. No subtitle when the pane is unknown. The body is what is
    /// asked: the question, else what the approval waits on ("Waiting for
    /// approval: swift test"), as the session row says it.
    static func make(
        for approval: ApprovalPresentation,
        containerLabel: String?,
        locale: Locale
    ) -> Words {
        let summary = approval.summary.flatMap { $0.isEmpty ? nil : $0 }
        let subtitle = containerLabel.flatMap(AgentNotificationEmitter.subtitle(forContainerLabel:))
        if approval.isQuestion {
            let title = approval.provider.waitTitle(for: .question(detail: nil)).resolved(in: locale)
            return Words(title: title, subtitle: subtitle, body: approval.questions.first?.prompt ?? summary ?? approval.toolName)
        }
        // Worded by the same function as a wait Weir holds no request
        // for: a command on one line, a path as its file's name.
        let action = AgentTools.action(of: approval.toolName)
        let wait = PromptWait.approval(PromptApproval(
            tool: approval.toolName,
            action: action,
            subject: summary.map { PromptApproval.subject($0, action: action) },
            detail: summary
        ))
        let title = approval.provider.waitTitle(for: wait).resolved(in: locale)
        return Words(title: title, subtitle: subtitle, body: PromptWaitText.line(wait).resolved(in: locale))
    }

    /// The request as the history keeps it: a question and its words, or an
    /// approval and what it waits on, as the banner's body names them.
    static func event(for approval: ApprovalPresentation) -> NotificationEvent {
        let summary = approval.summary.flatMap { $0.isEmpty ? nil : $0 }
        if approval.isQuestion {
            return .wait(agent: approval.provider, wait: .question, fact: approval.questions.first?.prompt ?? summary)
        }
        let action = AgentTools.action(of: approval.toolName)
        let subject = summary.map { PromptApproval.subject($0, action: action) }
        return .wait(agent: approval.provider, wait: .approval, fact: subject ?? approval.toolName)
    }
}
