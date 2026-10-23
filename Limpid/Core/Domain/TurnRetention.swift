// TurnRetention.swift
// Limpid — how long turn records are kept, and the turns a person may still need, each spared some of the limits.

import Foundation

/// The limits turn records are kept within: a turn started longer ago
/// than `maxAgeSeconds`, or past the newest `maxPerConversation` of its
/// conversation, goes with its refs, unless it is protected.
struct TurnRetentionLimits: Equatable, Sendable {
    var maxAgeSeconds: Int
    var maxPerConversation: Int
    /// Past this many bytes of turn snapshots in one repository, the
    /// oldest turns that may go, go too.
    var maxRepositoryBytes: Int? = 500 * 1024 * 1024
    /// Past this many turns kept in all, the oldest go, unread ones last:
    /// each costs about a kilobyte in every pass, and a pass past the
    /// bridge's 16 MB never runs.
    var maxTurns: Int? = 8000

    /// The days a turn is kept and the turns a conversation keeps until the
    /// person sets their own (`TurnRetentionSettings`).
    static let standardDays = 14
    static let standardTurns = 200

    /// 14 days or 200 turns, whichever comes first, 500 MB a repository,
    /// and 8,000 turns in all.
    static let standard = TurnRetentionLimits(
        maxAgeSeconds: standardDays * 24 * 60 * 60,
        maxPerConversation: standardTurns
    )

    /// Whether going from `old` to `new` keeps fewer turns by its age or
    /// its count limit.
    static func isNarrowing(from old: TurnRetentionLimits, to new: TurnRetentionLimits) -> Bool {
        new.maxAgeSeconds < old.maxAgeSeconds || new.maxPerConversation < old.maxPerConversation
    }
}

/// What a change of the person's limits (Advanced) takes, which
/// decides whether it is asked before it is saved. Records a sweep
/// deletes cannot come back, so a change that would delete some waits for
/// the person to confirm it; a wider limit, or a narrower one that deletes
/// nothing yet, is saved as it is made. How many a change deletes is the
/// sweep's to say (`AgentProjectionAdapter.turnsTaken`), so the number asked
/// with is the one it deletes.
enum TurnRetentionCut {
    /// Whether going from `old` to `new` asks first: only a decrease, and
    /// only when it would delete a record now.
    static func needsConfirmation(
        from old: TurnRetentionSettings,
        to new: TurnRetentionSettings,
        removing count: Int
    ) -> Bool {
        isDecrease(from: old, to: new) && count > 0
    }

    static func isDecrease(from old: TurnRetentionSettings, to new: TurnRetentionSettings) -> Bool {
        new.days < old.days || new.turns < old.turns
    }
}

/// The turns the host knows a person may still need. Each set is spared
/// different limits, as its own comment says: a held turn no limit takes,
/// while an unread one is spared the age and size limits, not the count
/// limits.
struct TurnProtection: Equatable, Sendable {
    /// Unread turns whose session is open: spared the age and size limits
    /// until read, not the count limits, and holding back nothing after
    /// them.
    var protectedTurnIDs: Set<TurnID>
    /// Turns held for now: in a range a review has open or keeps comments
    /// for, or read a moment ago. Kept, and no later turn of their worktree
    /// goes while they are.
    var heldTurnIDs: Set<TurnID> = []
    /// Conversations shown in a pane now: their latest turns stay whatever
    /// their age.
    var shownConversations: Set<ConversationKey>

    /// Unread turns of open sessions past `unreadLimit`, which the limits
    /// may take in spite of being unread (`of`); for the log.
    var unreadPastAge = 0

    /// How long a turn just read stays protected: the toast's Undo can put
    /// it back to unread, and it must still be there to be read again.
    static let readGrace: TimeInterval = 10 * 60
    /// How long an unread turn of an open session is spared the age limit,
    /// however long the session is kept open: a session never read would
    /// keep every turn otherwise. The count limits apply to it all
    /// along.
    static let unreadLimit: TimeInterval = 90 * 24 * 60 * 60

    /// What the host knows that protects turns.
    struct Sources {
        /// Whether a pass has reported the turns (`TurnHistory.hasLoaded`).
        var hasLoaded: Bool
        var history: [ConversationKey: [TurnSummary]]
        /// Past the viewed line, or seen in its pane.
        var isRead: (TurnSummary) -> Bool
        /// When a turn was marked read by being seen.
        var readAt: (TurnID) -> Date? = { _ in nil }
        /// When a conversation's viewed line last moved.
        var lineMovedAt: (ConversationKey) -> Date? = { _ in nil }
        /// The ranges reviews have open or keep comments for.
        var ranges: [ReviewTurnRange] = []
        var shownConversations: Set<ConversationKey> = []
        /// The panes the session's tabs hold, upper-cased: a turn's session
        /// is open while its pane is, whether its agent still runs or not.
        var openPanes: Set<String> = []
    }

    /// What protects turns now, or `nil` before a pass has reported the
    /// turns, when no turn is known to be read and the sweep must wait
    /// rather than guess. Protected: every ended, prompted turn not yet
    /// read whose session is open (its pane is still in a tab, or its
    /// conversation runs in one) and that started within `unreadLimit`. An
    /// unread turn stops being unread when its session is closed, so it
    /// is kept no longer than the limits keep any turn.
    /// Held: the turns of the open ranges, and one read within `readGrace`
    /// (by being seen, or by its conversation's line moving). A turn still
    /// running is held by the rules themselves.
    static func of(_ sources: Sources, now: Date) -> TurnProtection? {
        guard sources.hasLoaded else { return nil }
        let isRecent = { (date: Date?) in date.map { now.timeIntervalSince($0) < readGrace } ?? false }
        var protected: Set<TurnID> = []
        var held = Set(sources.ranges.flatMap(\.turnIDs))
        var unreadPastAge = 0
        for (conversation, turns) in sources.history {
            let isLineRecent = isRecent(sources.lineMovedAt(conversation))
            let isShown = sources.shownConversations.contains(conversation)
            for turn in turns where turn.phase != .started && turn.hasPrompt {
                if !sources.isRead(turn) {
                    guard isShown || sources.openPanes.contains(turn.paneID.uppercased()) else { continue }
                    // A start that does not read is no evidence of age.
                    let age = UnreadTurnRules.date(turn.startedAt).map { now.timeIntervalSince($0) } ?? 0
                    if age < unreadLimit {
                        protected.insert(turn.turnID)
                    } else {
                        unreadPastAge += 1
                    }
                } else if isLineRecent || isRecent(sources.readAt(turn.turnID)) {
                    held.insert(turn.turnID)
                }
            }
        }
        var protection = TurnProtection(
            protectedTurnIDs: protected,
            heldTurnIDs: held,
            shownConversations: sources.shownConversations
        )
        protection.unreadPastAge = unreadPastAge
        return protection
    }

    /// The conversations the deletion of `gone` left with no turns, whose
    /// viewed line goes too. Each turn's conversation is the one the history
    /// had when its deletion was asked for: a pass during the deletion may
    /// already have dropped it, and a conversation the history no longer has
    /// has no turns left, unless it is in `remaining`, the conversations of
    /// turns still being deleted or not deleted after all, which a pass may
    /// have missed only while their records were moved aside. One a turn's
    /// conversation was never known for is left alone.
    static func conversationsEmptied(
        by gone: [TurnID: ConversationKey?],
        remaining: Set<ConversationKey>,
        history: [ConversationKey: [TurnSummary]]
    ) -> Set<ConversationKey> {
        let goneIDs = Set(gone.keys)
        return Set(gone.values.compactMap(\.self)).subtracting(remaining).filter { conversation in
            (history[conversation] ?? []).allSatisfy { goneIDs.contains($0.turnID) }
        }
    }
}
