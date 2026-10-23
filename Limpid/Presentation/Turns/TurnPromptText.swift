// TurnPromptText.swift
// Limpid — the instruction a turn shows for the prompt it began from.

import Foundation

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
            prompt.head
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
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
    /// words are cut: the harness's are short already, and cut they would
    /// say less than nothing.
    static func shortInstruction(_ prompt: TurnPrompt, characters: Int, locale: Locale) -> String? {
        guard let instruction = instruction(prompt, locale: locale) else { return nil }
        guard prompt.kind == .text, instruction.count > characters else { return instruction }
        return String(instruction.prefix(characters)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
