// ConversationChoice.swift
// Limpid — one conversation of a worktree, named as the changes panel and the review name it ("Claude #2"), with what it has left to read.

import Foundation

/// One agent's conversation in a worktree, as every surface that offers a
/// choice of conversations names it: the changes panel's filter and
/// row badges, the review tab's scope menu headings, and its destination
/// menu. Apart from either surface, so the review does not read the changes
/// panel's model to name a conversation.
struct ConversationChoice: Equatable, Sendable {
    let conversation: ConversationKey
    /// Its place among the conversations of the same kind, from 1, when
    /// there is more than one ("Claude #2"); `nil` when the kind alone
    /// names it.
    let ordinal: Int?
    let unviewedCount: Int
    /// The tab whose pane runs it, here or in another workspace.
    /// Optional because a conversation the filter lists may have no
    /// pane left: it ended, or its pane closed.
    var liveTab: LiveTab?
    /// What its latest turn was asked, which tells one conversation of a
    /// kind from another where their names are only numbers. `nil`
    /// before its first turn is recorded.
    var latestPrompt: TurnPrompt?
    /// When it last did something: its latest turn's end, or its start
    /// while that turn runs. What the menus order conversations by, newest
    /// first, and the time they show. `nil` before its first turn, or when
    /// the record's times cannot be read.
    var lastActivity: Date?

    /// Whether a pane of the session the panel reads runs it, the same
    /// fact the panel's `running` reads.
    var isRunningHere: Bool {
        liveTab?.isInSession == true
    }

    /// Where a menu of conversations lists it.
    var section: Section {
        if isRunningHere {
            .running
        } else if unviewedCount > 0 {
            .unviewed
        } else {
            .viewed
        }
    }

    /// `choices` with the latest activity first: the conversation the
    /// person just worked with is at the top of its section, not under
    /// every older one. Those with no time keep their order, last.
    static func byLatestActivity(_ choices: [ConversationChoice]) -> [ConversationChoice] {
        choices.enumerated().sorted { lhs, rhs in
            switch (lhs.element.lastActivity, rhs.element.lastActivity) {
            case let (left?, right?) where left != right: left > right
            case (.some, nil): true
            case (nil, .some): false
            default: lhs.offset < rhs.offset
            }
        }
        .map(\.element)
    }

    /// The tab whose pane runs a conversation, and where that tab is.
    struct LiveTab: Equatable, Sendable {
        /// The tab's title as the pane strip shows it, empty before the
        /// terminal has named it.
        let title: String
        /// Whether the tab is in the session the panel reads, which is what
        /// the panel's `running` counts.
        let isInSession: Bool
        /// Where a tab outside the session is (`CheckoutName.place`).
        /// Optional, as a tab in the session needs no place said, and a
        /// worktree whose project is gone has no name to say.
        var checkoutPlace: CheckoutName.Place?
    }

    /// Where a conversation goes in a menu of them.
    enum Section: Equatable, Sendable, CaseIterable {
        /// A pane of this session runs it.
        case running
        /// Ended or run elsewhere, with turns still to read.
        case unviewed
        /// Nothing left to read.
        case viewed
    }
}
