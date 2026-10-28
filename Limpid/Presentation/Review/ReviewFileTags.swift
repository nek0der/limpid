// ReviewFileTags.swift
// Limpid — which conversations' turns changed each file of a review range, for the stacked diff's headers.

import Foundation

/// The tags on the stacked diff's file headers: for each file, every
/// conversation whose turns within the range changed it, with those turns.
/// Pure, from the turns the range reads through and each turn's own files
/// (`WorktreeChanges.turnPaths`), so what is tagged is tested without Git.
enum ReviewFileTags {
    /// The tags by worktree-relative path. `turns` are the range's, every
    /// conversation's, in the timeline's order
    /// (`ReviewScopeCatalog.turnsThrough`); `paths` gives a turn's files,
    /// `nil` while they have not been read or cannot be, and that turn
    /// tags nothing until they are. `conversations` names them, as the
    /// changes panel names them. Nothing in a worktree of one
    /// conversation, where every tag would name the same one.
    static func tags(
        turns: [TurnSummary],
        paths: (TurnID) -> Set<String>?,
        conversations: [ConversationChoice]
    ) -> [String: [ReviewFileTag]] {
        guard conversations.count > 1 else { return [:] }
        let names = Dictionary(conversations.map { ($0.conversation, $0) }, uniquingKeysWith: { first, _ in first })
        // Each path's conversations in the order their first turn there
        // came, and each conversation's turns in the timeline's order.
        var touched: [String: [(conversation: ConversationKey, turns: [Int])]] = [:]
        for turn in turns {
            guard case .changed = turn.changes, let changed = paths(turn.turnID) else { continue }
            for path in changed {
                var entries = touched[path] ?? []
                if let index = entries.firstIndex(where: { $0.conversation == turn.conversation }) {
                    entries[index].turns.append(turn.displayNumber)
                } else {
                    entries.append((turn.conversation, [turn.displayNumber]))
                }
                touched[path] = entries
            }
        }
        return touched.mapValues { entries in
            entries.map { entry in
                ReviewFileTag(
                    provider: entry.conversation.provider,
                    title: names[entry.conversation]?.title,
                    ordinal: names[entry.conversation]?.ordinal,
                    turns: entry.turns,
                    identity: names[entry.conversation]?.identity
                )
            }
        }
    }

    /// The range's turns whose files Git could not read (`isUnreadable`: a
    /// tree the retention sweep deleted), grouped by conversation as a tag
    /// is: any file's tags may lack them, which the header's tooltip says
    /// rather than tag less without a word. Nothing in a worktree of one
    /// conversation, which shows no tags.
    static func unreadable(
        turns: [TurnSummary],
        isUnreadable: (TurnID) -> Bool,
        conversations: [ConversationChoice]
    ) -> [ReviewFileTag] {
        guard conversations.count > 1 else { return [] }
        let names = Dictionary(conversations.map { ($0.conversation, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [(conversation: ConversationKey, turns: [Int])] = []
        for turn in turns {
            guard case .changed = turn.changes, isUnreadable(turn.turnID) else { continue }
            if let index = entries.firstIndex(where: { $0.conversation == turn.conversation }) {
                entries[index].turns.append(turn.displayNumber)
            } else {
                entries.append((turn.conversation, [turn.displayNumber]))
            }
        }
        return entries.map { entry in
            ReviewFileTag(
                provider: entry.conversation.provider,
                title: names[entry.conversation]?.title,
                ordinal: names[entry.conversation]?.ordinal,
                turns: entry.turns,
                identity: names[entry.conversation]?.identity
            )
        }
    }

    /// How many tags a header shows before "2 more": the conversations
    /// that changed a file most often number one or two, and a header of
    /// many tags ran past the window's narrowest width and took the path's
    /// room.
    static let shownLimit = 2

    /// The tags a header shows, and how many more its "2 more" counts; the
    /// whole list is in its tooltip and what VoiceOver reads.
    static func shown(_ tags: [ReviewFileTag]) -> (shown: [ReviewFileTag], more: Int) {
        guard tags.count > shownLimit else { return (tags, 0) }
        return (Array(tags.prefix(shownLimit)), tags.count - shownLimit)
    }
}
