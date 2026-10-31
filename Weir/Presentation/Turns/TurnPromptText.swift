// TurnPromptText.swift
// Weir — the instruction a turn shows for the prompt it began from.

import Foundation
import WeirDomain

/// The one place a turn's prompt becomes the words the changes panel, the
/// review's scope, and a finished turn's notification show for it. A prompt
/// the agent's harness wrote carries tags and ids nobody can read
/// ("<task-notification> <task-id>…"), so it is worded by what it was rather
/// than quoted.
enum TurnPromptText {
    /// The person's words, trimmed, or what the harness's prompt was;
    /// `nil` for the person's prompt when none was kept.
    static func instruction(_ prompt: TurnPrompt, locale: Locale) -> String? {
        switch prompt.kind {
        case .text:
            words(prompt.head)
        case .goal:
            // The goal's objective is the person's own words, so it is
            // quoted after the command they set it with, as they typed it.
            // The command is Codex's own word, not translated.
            if let objective = words(prompt.head) {
                LocalizedStringResource(
                    "/goal \(objective)",
                    comment: "A turn the agent began on its own toward the person's goal, in place of the turn's prompt; argument: the goal"
                ).resolved(in: locale)
            } else {
                LocalizedStringResource(
                    "/goal",
                    comment: "A turn the agent began on its own toward the person's goal, in place of the turn's prompt, its words not kept"
                ).resolved(in: locale)
            }
        case .backgroundTask:
            LocalizedStringResource(
                "Background work done",
                comment: "A turn the agent began on its own when background work it started ended, in place of the turn's prompt"
            ).resolved(in: locale)
        case .subagentMessage:
            LocalizedStringResource(
                "Message from a subagent",
                comment: "A turn the agent began on its own when a subagent handed its result back, in place of the turn's prompt"
            ).resolved(in: locale)
        case .injected:
            LocalizedStringResource(
                "Automatic message to the agent",
                comment: "A turn begun by a message the agent's tool added rather than the person, in place of the turn's prompt"
            ).resolved(in: locale)
        }
    }

    /// The instruction cut to its first `characters`, with "…" where it
    /// was cut, for a menu line beside other facts (the review's scope
    /// choices, a conversation's line in the filter). Only the person's
    /// words are cut, a goal's among them, and a goal's command is not counted:
    /// the harness's are short already, and cut they would say less than
    /// nothing.
    static func shortInstruction(_ prompt: TurnPrompt, characters: Int, locale: Locale) -> String? {
        guard prompt.kind.isThePersonsWords,
              let words = words(prompt.head), words.count > characters
        else { return instruction(prompt, locale: locale) }
        let cut = String(words.prefix(characters)).trimmingCharacters(in: .whitespaces) + "…"
        return instruction(TurnPrompt(kind: prompt.kind, head: cut), locale: locale)
    }

    /// `head` trimmed; `nil` when it has no words.
    private static func words(_ head: String?) -> String? {
        head
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}
