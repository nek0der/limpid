// ReviewScopeMenu.swift
// Weir — the review tab's one "Review Scope" menu: the worktree's unviewed turns, each conversation's, and the worktree's own
// comparisons.

import Foundation

/// What "Review Scope" lists, in one menu that also chooses the
/// conversation, so what the tab reads is said in one place: the
/// worktree's unviewed turns; under a heading per conversation (its badge,
/// name, and state) that conversation's unviewed turns, and its single
/// turns folded into a submenu; then the uncommitted changes and the
/// branch, which no conversation owns. A worktree of one conversation has no headings and
/// no worktree entry, which would be that conversation's again: the four
/// kinds of choice it always had.
///
/// The tab's own fixed choice stands in place of the one of its kind
/// computed now, so the menu always shows what the tab reads: once a turn
/// ends, the unviewed turns of now are not the ones the tab reads; a range
/// carried on by "Add to Scope" is no single turn's; changes outside turns
/// come and go; and an incomplete turn is never listed.
struct ReviewScopeMenu: Equatable {
    /// One entry: what it reads, and the conversation choosing it reads
    /// it for, `nil` for a choice no conversation owns.
    struct Choice: Equatable {
        let option: ReviewScopeOption
        let conversation: ConversationKey?
        let isChecked: Bool
    }

    /// One conversation's entries, under its heading.
    struct Section: Equatable {
        /// `nil` in a worktree of one conversation, which needs no heading.
        let conversation: ConversationChoice?
        let choices: [Choice]

        /// The entry a heading puts first, at the menu's top level: the
        /// conversation's unviewed turns, the tab's own fixed range in
        /// their place. `nil` when the first choice is a single turn.
        var lead: Choice? {
            guard let first = choices.first else { return nil }
            return switch first.option {
            case .unviewedTurns: first
            default: nil
            }
        }

        /// The conversation's single turns, newest first, which a menu of
        /// two or more conversations folds into a submenu under its lead,
        /// so each conversation takes a few lines however many turns it
        /// ran.
        var turns: [Choice] {
            Array(choices.dropFirst(lead == nil ? 0 : 1))
        }
    }

    /// How many conversations with turns to read the menu lists under
    /// headings of their own; those after them, by their latest activity,
    /// are each folded into one entry under "More Conversations". Fourteen
    /// conversations listed each under its heading ran past the screen, and
    /// put the uncommitted changes and the branch out of sight.
    static let listedLimit = 5

    /// The worktree's unviewed turns, with two or more conversations.
    let worktree: Choice?
    /// What the worktree's range is said with: its unviewed turns and
    /// their conversations, and the viewed turns it reads through
    /// ("Includes 16 viewed turns"); `nil` without a range.
    let worktreeCounts: ReviewScopeCatalog.RangeCounts?
    /// The conversations listed under their headings: those a pane of the
    /// session runs and the tab's own, always, then those with turns to
    /// read, newest first, up to `listedLimit` in all.
    let sections: [Section]
    /// Conversations with turns to read past `listedLimit`, each folded into
    /// one entry of its own under one heading.
    let more: [Section]
    /// The rest, every turn viewed, each folded into an entry of its own
    /// under one heading, so a worktree of many conversations keeps a menu
    /// of a few lines.
    let folded: [Section]
    let tail: [Choice]
    /// The conversation the label names beside the choice ("[Cl] Claude #4
    /// Unviewed Turns (T3–T6)"): the tab's, for a choice of its turns in a
    /// worktree of two or more conversations; `nil` otherwise.
    let labelConversation: ConversationChoice?

    /// What `option` is said with, when it is the worktree's range.
    func counts(of option: ReviewScopeOption) -> ReviewScopeCatalog.RangeCounts? {
        option == worktree?.option ? worktreeCounts : nil
    }

    /// Every entry, in the menu's order.
    var choices: [Choice] {
        [worktree].compactMap(\.self) + (sections + more + folded).flatMap(\.choices) + tail
    }

    static func make(_ tab: ReviewTabState, _ context: ReviewTabModel.Context) -> ReviewScopeMenu {
        let selection = ReviewTabModel.shown(tab.selection, context)
        let named = context.conversations
        let isShared = named.count > 1
        func choice(_ option: ReviewScopeOption, _ conversation: ConversationKey?) -> Choice {
            let isSelected = option == selection && (!option.isConversations || conversation == tab.conversation)
            return Choice(option: option, conversation: conversation, isChecked: isSelected)
        }

        var worktreeOption: ReviewScopeOption? = isShared
            ? .worktreeUnviewedTurns(ReviewScopeCatalog.unviewedTurns(
                turns: context.worktreeTurns,
                isViewed: context.isViewed,
                isRestored: context.isRestored
            ))
            : nil
        if case .worktreeUnviewedTurns = selection {
            worktreeOption = selection
        }
        var worktreeCounts: ReviewScopeCatalog.RangeCounts?
        if let worktreeOption, case let .turns(range)? = worktreeOption.scope {
            worktreeCounts = ReviewScopeCatalog.counts(
                in: range,
                timeline: context.worktreeTurns,
                isViewed: context.isViewed,
                isRestored: context.isRestored
            )
        }

        var sections: [Section] = []
        var more: [Section] = []
        var folded: [Section] = []
        if isShared {
            var listed = named
            // The tab's conversation is always listed, whatever ran since.
            if let own = tab.conversation, !listed.contains(where: { $0.conversation == own }) {
                listed.append(ConversationChoice(conversation: own, ordinal: nil, unviewedCount: 0))
            }
            // By section, the latest activity first within each, as the
            // changes panel's filter lists them.
            let ordered = ConversationChoice.Section.allCases.flatMap { section in
                ConversationChoice.byLatestActivity(listed.filter { $0.section == section })
            }
            let kept = ordered.filter { $0.conversation == tab.conversation || $0.section == .running }.count
            var room = max(0, listedLimit - kept)
            for agent in ordered {
                let isOwn = agent.conversation == tab.conversation
                let turns = isOwn ? context.turns : context.conversationTurns[agent.conversation] ?? []
                var options = ReviewScopeCatalog.conversationOptions(
                    turns: turns,
                    isViewed: context.isViewed,
                    isRestored: context.isRestored
                )
                if isOwn {
                    place(selection, in: &options)
                }
                let section = Section(conversation: agent, choices: options.map { choice($0, agent.conversation) })
                if isOwn || agent.section == .running {
                    sections.append(section)
                } else if agent.section == .viewed {
                    folded.append(section)
                } else if room > 0 {
                    sections.append(section)
                    room -= 1
                } else {
                    more.append(section)
                }
            }
        } else {
            var options = ReviewScopeCatalog.conversationOptions(
                turns: context.turns,
                isViewed: context.isViewed,
                isRestored: context.isRestored
            )
            place(selection, in: &options)
            sections = [Section(conversation: nil, choices: options.map { choice($0, tab.conversation) })]
        }

        var tail = ReviewScopeCatalog.worktreeOptions(
            branchBase: context.branchBase,
            hasChangesOutsideTurns: context.hasChangesOutsideTurns
        )
        place(selection, in: &tail)

        let labelConversation: ConversationChoice? = if isShared, selection.isConversations, let own = tab.conversation {
            named.first { $0.conversation == own } ?? ConversationChoice(conversation: own, ordinal: nil, unviewedCount: 0)
        } else {
            nil
        }
        return ReviewScopeMenu(
            worktree: worktreeOption.map { choice($0, nil) },
            worktreeCounts: worktreeCounts,
            sections: sections,
            more: more,
            folded: folded,
            tail: tail.map { choice($0, nil) },
            labelConversation: labelConversation
        )
    }

    /// Puts the tab's fixed choice among `options`, one conversation's or
    /// the tail's, when it is of their sort and not one of them: in place
    /// of the one of its kind, else, for a turn, after the unviewed turns,
    /// where the turns are listed; a branch the list no longer offers goes
    /// last. The worktree's unviewed turns have an entry of their own.
    private static func place(_ selection: ReviewScopeOption, in options: inout [ReviewScopeOption]) {
        guard !options.contains(selection), let first = options.first,
              first.isConversations == selection.isConversations
        else { return }
        let sameKind = options.firstIndex { option in
            switch (option, selection) {
            case (.unviewedTurns, .unviewedTurns), (.uncommitted, .uncommitted), (.branch, .branch): true
            default: false
            }
        }
        if let sameKind {
            options[sameKind] = selection
        } else if case .branch = selection {
            options.append(selection)
        } else if selection.isConversations {
            options.insert(selection, at: min(1, options.count))
        }
    }
}
