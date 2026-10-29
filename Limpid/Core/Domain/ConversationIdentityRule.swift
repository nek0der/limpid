// ConversationIdentityRule.swift
// Limpid — which identity color each active conversation of a worktree holds, kept while it stays active.

import Foundation

/// The rule that hands a worktree's active conversations their identity
/// colors, as indices into the palette (`SupervisionTokens.conversationIdentity`).
/// A conversation keeps its index for as long as it stays active, so the
/// color that matches its tab to its cards never moves under the person's
/// eye when another conversation starts or ends. Pure: what was handed out
/// before is passed in (`ConversationIdentityStore` keeps it).
enum ConversationIdentityRule {
    /// The index of each conversation in `active`.
    ///
    /// - `active`: the conversations running in a pane of the session and
    ///   those with unviewed turns, in the order they were created
    ///   (`ChangesPanelModel.agents`), which is the order new ones are
    ///   handed out in.
    /// - `previous`: what the last call handed out. A conversation in it
    ///   keeps its index; one no longer in `active` gives its index back.
    /// - A new conversation takes the lowest index nobody holds; with the
    ///   palette full, the lowest of those held by the fewest, so a color
    ///   is shared by as few conversations as it can be.
    ///
    /// Empty while fewer than two are active: one conversation needs
    /// nothing to tell it apart, as with the kind's number.
    static func assign(
        active: [ConversationKey],
        previous: [ConversationKey: Int],
        paletteCount: Int
    ) -> [ConversationKey: Int] {
        guard active.count > 1, paletteCount > 0 else { return [:] }
        var assigned: [ConversationKey: Int] = [:]
        var uses = Array(repeating: 0, count: paletteCount)
        for conversation in active {
            guard assigned[conversation] == nil, let index = previous[conversation], uses.indices.contains(index) else { continue }
            assigned[conversation] = index
            uses[index] += 1
        }
        for conversation in active where assigned[conversation] == nil {
            // The fewest uses wins, and the lowest index among equals,
            // which is the lowest free one while any is free.
            guard let fewest = uses.min(), let index = uses.firstIndex(of: fewest) else { continue }
            assigned[conversation] = index
            uses[index] += 1
        }
        return assigned
    }
}
