// ConversationChoice.swift
// Weir — one conversation of a worktree, named as the changes panel and the review name it, with what it has left to read.

import Foundation

/// One agent's conversation in a worktree, as every surface that offers a
/// choice of conversations names it: the changes panel's filter and
/// row badges, the review tab's scope menu headings, and its destination
/// menu. Apart from either surface, so the review does not read the changes
/// panel's model to name a conversation.
struct ConversationChoice: Equatable, Sendable {
    let conversation: ConversationKey
    /// What names it (`ConversationTitleRule`). Optional because a
    /// conversation nobody named, whose first prompt was not kept, has
    /// none, and is named by its kind and number instead.
    var title: String?
    /// Its place among the worktree's conversations of the same kind, from
    /// 1, where its name alone does not tell it apart: an untitled one
    /// beside another of its kind ("Claude #2"), or a titled one whose
    /// title another of its kind has too ("Fix tests #2"). `nil` when the
    /// title, or the kind alone, names it.
    let ordinal: Int?
    let unviewedCount: Int
    /// The tab whose pane runs it, here or in another workspace.
    /// Optional because a conversation the filter lists may have no
    /// pane left: it ended, or its pane closed.
    var liveTab: LiveTab?
    /// What its latest turn was asked, which VoiceOver reads in full after
    /// its name in a menu (`ConversationText.value`); the menu's line
    /// leaves it out, as a prompt would widen the whole menu. `nil` before
    /// its first turn is recorded.
    var latestPrompt: TurnPrompt?
    /// When it last did something: its latest turn's end, or its start
    /// while that turn runs. What the menus order conversations by, newest
    /// first, and the time they show. `nil` before its first turn, or when
    /// the record's times cannot be read.
    var lastActivity: Date?
    /// Its identity color, an index into
    /// `SupervisionTokens.conversationIdentity`, which it keeps while it
    /// runs here or has turns to read (`ConversationIdentityRule`). Optional
    /// because a worktree with one such conversation shows none, and a
    /// conversation that ended with every turn viewed gives its color back.
    var identity: Int?

    /// Whether it has a name of its own, beyond its kind: a title or a
    /// number. Where it has none, a pane running it is named after the
    /// pane instead.
    var hasOwnName: Bool {
        title != nil || ordinal != nil
    }

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
        /// The name the person gave the tab (`Tab.titleOverride`), only
        /// for the conversation the tab's title stands for: the one in
        /// `Tab.latestAgentSessionPaneID`'s pane, or with none, the tab's one
        /// conversation (`ConversationTabs`). Another conversation
        /// split beside it is not what they named, and has `nil`, as has
        /// a tab they never renamed.
        var titleOverride: String?
        /// The tab's place among the session's tabs, from 1, in the
        /// order the pane strip shows them. `nil` for a tab outside the
        /// session, whose place is said by `checkoutPlace` instead.
        var position: Int?
        /// The provider's title for the conversation the pane runs, read
        /// live from the pane's agent: its session's name (Claude's
        /// `/rename`, Codex's thread name), else the title it generated
        /// (Claude's `ai-title`), cleaned as the tab's title is, by the one
        /// rule on the Rust side (`WeirRustTitleResolver`). `nil` until
        /// the provider names it.
        var providerTitle: String?
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
