// PromptWaitText.swift
// Limpid — a wait at the agent's own prompt in words, the one way every place says it.

import Foundation

/// Beside `PromptWait`, below every layer that words one, so the banner and
/// the notification history in Core say a wait as the session row, the
/// Needs Attention list, and the decision bar in Presentation do, without
/// Core reaching up for it.
enum PromptWaitText {
    /// An approval and a question as held ones read ("Waiting for approval:
    /// notes.txt", "Question: Which color?"), a sign-in as one, and any other
    /// wait as one for a response, with the agent's words when it gave any.
    static func line(_ wait: PromptWait) -> LocalizedStringResource {
        switch wait {
        case let .approval(approval):
            approval.fact.map {
                LocalizedStringResource(
                    "Waiting for approval: \($0)",
                    comment: "Needs Attention row; the command an approval request waits on"
                )
            } ?? LocalizedStringResource("Needs approval")
        case let .question(detail):
            detail.map {
                LocalizedStringResource("Question: \($0)", comment: "Needs Attention row; the start of the agent's question")
            } ?? LocalizedStringResource("Needs answer")
        case .signIn:
            LocalizedStringResource("Needs sign-in")
        case let .unclassified(detail):
            detail.map {
                LocalizedStringResource(
                    "Needs response: \($0)",
                    comment: "Needs Attention row; the agent's own words while it waits at its prompt, as neither approval nor question"
                )
            } ?? LocalizedStringResource("Needs response")
        }
    }
}
