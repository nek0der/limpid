// ConversationTitleRule.swift
// Weir — which of a conversation's titles names it, so the changes panel and the review say a title rather than "Claude #3".

import Foundation

/// The one rule for a conversation's title, from the names it can have:
/// the person's own name for its tab first, as what they chose wins over
/// what a program guessed, and after it the name they gave a tab it ran in
/// before, which outlives the tab (`WorkspaceSession.conversationTabNames`);
/// then the provider's live title, already chosen and cleaned on the Rust
/// side as the tab's title is (`conversation_title` in
/// `rust/weir-agent-core/src/title.rs`); then the title its newest turn
/// recorded by the same rule, which still names a conversation whose pane
/// is gone; and last the first thing it was asked. A value of spaces says
/// nothing and is passed over, and only a value's first line is taken, as
/// a name stands on one line.
package enum ConversationTitleRule {
    package static func title(
        tabName: String?,
        rememberedTabName: String?,
        liveTitle: String?,
        recordedTitle: String?,
        firstPrompt: TurnPrompt?
    ) -> String? {
        // A prompt the harness wrote is no name: worded by its kind, it
        // would name every conversation a background task woke alike.
        let prompt = firstPrompt.flatMap { $0.kind.isThePersonsWords ? $0.head : nil }
        return [tabName, rememberedTabName, liveTitle, recordedTitle, prompt].lazy.compactMap(firstLine).first
    }

    /// The first line that says something, trimmed; `nil` for none.
    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
