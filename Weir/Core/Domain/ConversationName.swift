// ConversationName.swift
// Weir — the name of the first agent conversation that ran in a tab, and the rules that keep it.

import Foundation

/// What the first agent conversation of a tab was called, and which
/// conversation that was.
///
/// Not the agent tab's title, which is whatever OSC 2 set last: "claude
/// --continue" while the agent starts, the agent's own words while it runs,
/// and the shell's folder once it leaves. Named by that, a tab, or a row on
/// a detached HEAD, would move under a different name while staying in its
/// place, and a place is only worth keeping if it can be found there. The
/// name here follows one conversation while it runs and stays once it
/// ends.
///
/// The rules read the sessions a pass observed as `Observed` values, which
/// say which conversation each is and when it started, and nothing more.
/// The caller's `title` closure answers what an observed session is called
/// now, or `nil` while it has no title yet; how it decides is the caller's.
struct ConversationName: Codable, Equatable, Sendable {
    /// One agent session a pass observed in one pane of the tab: which
    /// conversation it is, without its title.
    struct Observed: Equatable, Sendable {
        let provider: AgentKind
        let paneID: UUID
        let conversationID: String?
        let startedAt: Date?
    }

    /// The conversation's title, as the caller's `title` last gave it.
    let name: String
    let provider: AgentKind
    /// The pane the conversation runs in, or last ran in: what a pane
    /// moved to another tab takes the name with.
    let paneID: UUID
    /// The provider's conversation id; `nil` only in a name a build before
    /// Codex's ids counted saved for a Codex conversation, which is told
    /// apart by its pane and the moment it started instead. A name taken
    /// now always has one, since a badge without one names nothing.
    let conversationID: String?
    /// When the conversation's session began, which orders a row's tabs by
    /// whose conversation came first; `nil` when its record did not say.
    let startedAt: Date?

    /// Whether `observed` is this conversation: the same id, or, without
    /// one, the same session in the same pane, whatever id the session now
    /// reports. A resumed session (`claude --continue`) keeps its id, so it
    /// keeps its name too. Without an id or a start there is nothing to tell
    /// the next conversation in the pane from this one, so it is taken as
    /// another: the name then stays as it was rather than move to the next
    /// conversation's.
    func isSame(_ observed: Observed) -> Bool {
        guard observed.provider == provider else { return false }
        if let conversationID {
            return observed.conversationID == conversationID
        }
        guard let startedAt, observed.paneID == paneID else { return false }
        return observed.startedAt == startedAt
    }

    /// The name a tab keeps after a pass observed `observed` in it: the
    /// remembered conversation's current title while it still runs there,
    /// else the remembered name as it was; with none remembered, the
    /// earliest observed conversation that has a title. A conversation that
    /// started after the first never renames the tab, so a second agent, or
    /// a new session in the same pane, leaves the row where the person
    /// found it.
    ///
    /// `title` is asked only of the sessions that could name the tab, in
    /// the order they would win, and only until one answers: resolving a
    /// title is not free, and a tab runs this on every pass.
    static func remembered(
        _ current: ConversationName?,
        observed: [Observed],
        title: (Observed) -> String?
    ) -> ConversationName? {
        // Ordered, so the same conversation open in two panes (resumed in
        // a split) always answers from the same one.
        let ordered = observed.sorted { isEarlier(key($0), key($1)) }
        if let current {
            // The name and the pane follow the conversation, which may have
            // resumed in another pane; its first start stays what orders it.
            // A name taken without an id keeps the one its session reports
            // now, which follows the conversation from then on.
            for candidate in ordered where current.isSame(candidate) {
                if let name = title(candidate) {
                    return ConversationName(
                        name: name,
                        provider: current.provider,
                        paneID: candidate.paneID,
                        conversationID: current.conversationID ?? candidate.conversationID,
                        startedAt: current.startedAt
                    )
                }
            }
            return current
        }
        for candidate in ordered {
            if let name = title(candidate) {
                return ConversationName(
                    name: name,
                    provider: candidate.provider,
                    paneID: candidate.paneID,
                    conversationID: candidate.conversationID,
                    startedAt: candidate.startedAt
                )
            }
        }
        return nil
    }

    /// What orders conversations: when they started, one with no start
    /// last, then provider and pane, so the same input always gives the
    /// same order.
    private struct OrderKey {
        let startedAt: Date?
        let provider: AgentKind
        let paneID: UUID
    }

    private static func key(_ observed: Observed) -> OrderKey {
        OrderKey(startedAt: observed.startedAt, provider: observed.provider, paneID: observed.paneID)
    }

    private static func key(_ name: ConversationName) -> OrderKey {
        OrderKey(startedAt: name.startedAt, provider: name.provider, paneID: name.paneID)
    }

    private static func isEarlier(_ lhs: OrderKey, _ rhs: OrderKey) -> Bool {
        let left = lhs.startedAt ?? .distantFuture
        let right = rhs.startedAt ?? .distantFuture
        if left != right {
            return left < right
        }
        if lhs.provider != rhs.provider {
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        return lhs.paneID.uuidString < rhs.paneID.uuidString
    }

    /// Whether `lhs` started before `rhs` (`OrderKey`).
    static func isEarlier(_ lhs: ConversationName, _ rhs: ConversationName) -> Bool {
        isEarlier(key(lhs), key(rhs))
    }

    /// The earlier of two names, either of which may be missing: what a tab
    /// keeps when a pane brings its conversation's name in from another.
    static func earlier(_ lhs: ConversationName?, _ rhs: ConversationName?) -> ConversationName? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        return isEarlier(rhs, lhs) ? rhs : lhs
    }

    /// The first of `names` to start: the conversation that names a
    /// detached row whose tabs hold them (`RowName`).
    static func first(_ names: [ConversationName]) -> ConversationName? {
        names.min(by: isEarlier)
    }

    /// The same name with its pane renumbered as `paneIDs` says, as a tab
    /// opened again gives its panes new ids. A pane not among them (one
    /// that closed after its conversation named the tab) keeps its id:
    /// the name still names the tab, and no pane takes it elsewhere.
    func remapped(_ paneIDs: [UUID: UUID]) -> ConversationName {
        ConversationName(
            name: name,
            provider: provider,
            paneID: paneIDs[paneID] ?? paneID,
            conversationID: conversationID,
            startedAt: startedAt
        )
    }
}
