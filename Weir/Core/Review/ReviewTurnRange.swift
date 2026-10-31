// ReviewTurnRange.swift
// Weir — a run of turns, fixed when review opened, as one comparison of two snapshots.

import CryptoKit
import Foundation

/// The turns a review reads, fixed when it opened: from the tree the first
/// of them began at to the tree the one that ended last ended at. A later
/// turn does not join on its own ("Add to Scope" asks), and a later edit to the worktree
/// does not move the comparison, so a comment written against the range
/// keeps meaning what it meant.
///
/// Never empty, and every turn in it has a recorded number: the first turn
/// and the rest are kept apart so the type cannot hold none, and decoding
/// refuses a range that would.
///
/// A range may run across conversations: the worktree's unviewed turns are
/// one comparison, from the oldest unviewed turn's begin to the end of the
/// one that ended last, whatever conversation each is in. Its turns
/// are in the timeline's order (`WorktreeTimeline`), by when each started,
/// so the turn it ends at need not be its last: one that started early and
/// ran long ends it. `conversation` then names the end turn's, which is
/// what an older build reads the range as: the trees compared are the same
/// two, so the diff it shows is the same.
struct ReviewTurnRange: Equatable, Hashable, Codable, Sendable {
    /// The end turn's conversation: the one the range is read for, where
    /// only one is ("Mark as Viewed", the destination pane).
    let conversation: ConversationKey
    /// Every conversation with a turn in the range, in the order their
    /// turns first appear; `[conversation]` for a range of one. Written as
    /// a key of its own, which a build from before it was kept leaves
    /// unread and, rewriting the draft, drops: the range then reads as
    /// `conversation`'s alone (`docs/data-migration.md`).
    let conversations: [ConversationKey]
    let firstTurnID: TurnID
    let restTurnIDs: [TurnID]
    /// The turn whose end the range compares: the one that ended last, by
    /// the record's times (`WorktreeTimeline.lastEnded`). Written as a key
    /// of its own; a draft from before it was kept names none, and its
    /// range ended at its last turn, which is what it reads as.
    let endTurnID: TurnID
    /// The first turn's number and the end turn's, each in its own
    /// conversation ("T6–T7"). Across conversations the two are not a run,
    /// and `numbers` is only their span.
    let firstNumber: Int
    let lastNumber: Int
    /// The tree the first turn began at, and the one the end turn ended at.
    let beginTree: String
    let endTree: String
    /// The work tree both snapshots were taken in.
    let root: String

    var turnIDs: [TurnID] {
        [firstTurnID] + restTurnIDs
    }

    var numbers: ClosedRange<Int> {
        min(firstNumber, lastNumber)...max(firstNumber, lastNumber)
    }

    /// What its comments and read marks belong to (`ReviewScope.scopeID`):
    /// the turns themselves, not their trees, so two turns that reach the
    /// same tree are still two ranges.
    var scopeID: String {
        let key = turnIDs.map(\.rawValue).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "turns:" + digest
    }

    /// Whether the range runs across more than one conversation.
    var isAcrossConversations: Bool {
        conversations.count > 1
    }

    /// The range over `turns`, in the timeline's order, ending at `end`'s
    /// end, or by default at the end of the turn that ended last
    /// (`WorktreeTimeline.lastEnded`). `nil` when there are none, when they
    /// are not in order (`isInOrder`), when `end` is not among them, when
    /// they belong to more than one work tree, when one is still running,
    /// when which ended last is not recorded, or when the first turn's
    /// begin or the end turn's end was not taken: a range whose ends are not
    /// both recorded would have to guess one of them, and an incomplete
    /// record is never guessed at.
    init?(turns: [TurnSummary], endingWith end: TurnSummary? = nil) {
        guard let first = turns.first,
              Self.isInOrder(turns),
              turns.allSatisfy({ $0.phase != .started }),
              let last = end ?? WorktreeTimeline.lastEnded(turns),
              turns.contains(where: { $0.turnID == last.turnID }),
              let begin = first.beginTree, let endTree = last.endTree,
              Self.isTreeName(begin.tree), Self.isTreeName(endTree.tree),
              Self.isOneWorkTree(turns, root: begin.root)
        else { return nil }
        self.init(
            conversation: last.conversation,
            conversations: Self.conversations(of: turns),
            firstTurnID: first.turnID,
            restTurnIDs: turns.dropFirst().map(\.turnID),
            endTurnID: last.turnID,
            firstNumber: first.displayNumber,
            lastNumber: last.displayNumber,
            beginTree: begin.tree,
            endTree: endTree.tree,
            root: begin.root
        )
    }

    private init(
        conversation: ConversationKey,
        conversations: [ConversationKey],
        firstTurnID: TurnID,
        restTurnIDs: [TurnID],
        endTurnID: TurnID,
        firstNumber: Int,
        lastNumber: Int,
        beginTree: String,
        endTree: String,
        root: String
    ) {
        self.conversation = conversation
        self.conversations = conversations
        self.firstTurnID = firstTurnID
        self.restTurnIDs = restTurnIDs
        self.endTurnID = endTurnID
        self.firstNumber = firstNumber
        self.lastNumber = lastNumber
        self.beginTree = beginTree
        self.endTree = endTree
        self.root = root
    }

    private enum CodingKeys: String, CodingKey {
        case conversation, conversations, firstTurnID, restTurnIDs, endTurnID, firstNumber, lastNumber, beginTree, endTree, root
    }

    /// Refuses a range no turns could have made: a tree that is not an
    /// object name (`isTreeName`), a conversation not among its
    /// conversations, or an end turn that is not one of its turns. A draft from before
    /// `conversations` was kept names one conversation, which is every
    /// conversation it has; one from before `endTurnID` ended at its last
    /// turn. Numbers may run backwards, even in one conversation: the
    /// timeline orders turns by when they started, and a turn can start
    /// before the one numbered before it (`WorktreeTimeline.isInOrder`).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let firstNumber = try container.decode(Int.self, forKey: .firstNumber)
        let lastNumber = try container.decode(Int.self, forKey: .lastNumber)
        let beginTree = try container.decode(String.self, forKey: .beginTree)
        let endTree = try container.decode(String.self, forKey: .endTree)
        let conversation = try container.decode(ConversationKey.self, forKey: .conversation)
        let conversations = try container.decodeIfPresent([ConversationKey].self, forKey: .conversations) ?? [conversation]
        guard Self.isTreeName(beginTree), Self.isTreeName(endTree) else {
            throw DecodingError.dataCorruptedError(
                forKey: .lastNumber,
                in: container,
                debugDescription: "not a range of recorded turns"
            )
        }
        guard conversations.contains(conversation) else {
            throw DecodingError.dataCorruptedError(
                forKey: .conversations,
                in: container,
                debugDescription: "the range's conversation is not among its conversations"
            )
        }
        let firstTurnID = try container.decode(TurnID.self, forKey: .firstTurnID)
        let restTurnIDs = try container.decode([TurnID].self, forKey: .restTurnIDs)
        let endTurnID = try container.decodeIfPresent(TurnID.self, forKey: .endTurnID) ?? restTurnIDs.last ?? firstTurnID
        guard endTurnID == firstTurnID || restTurnIDs.contains(endTurnID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .endTurnID,
                in: container,
                debugDescription: "the range's end turn is not among its turns"
            )
        }
        try self.init(
            conversation: conversation,
            conversations: conversations,
            firstTurnID: firstTurnID,
            restTurnIDs: restTurnIDs,
            endTurnID: endTurnID,
            firstNumber: firstNumber,
            lastNumber: lastNumber,
            beginTree: beginTree,
            endTree: endTree,
            root: container.decode(String.self, forKey: .root)
        )
    }

    /// The range with `turns` added after its end turn ("Add to Scope"): a
    /// new range, so a new scope, from the same first tree to the last new
    /// turn's end. `nil` when they do not follow its end turn in the same
    /// conversation and in their numbers' order, when they were recorded in
    /// another work tree, or when the last one's end was not taken.
    func extended(with turns: [TurnSummary]) -> ReviewTurnRange? {
        guard let last = turns.last, let end = last.endTree, Self.isTreeName(end.tree),
              zip(turns, turns.dropFirst()).allSatisfy({ $0.displayNumber < $1.displayNumber }),
              Self.isOneWorkTree(turns, root: root),
              turns.allSatisfy({ $0.conversation == conversation && $0.displayNumber > lastNumber && $0.phase != .started })
        else { return nil }
        return ReviewTurnRange(
            conversation: conversation,
            conversations: conversations,
            firstTurnID: firstTurnID,
            restTurnIDs: restTurnIDs + turns.map(\.turnID),
            endTurnID: last.turnID,
            firstNumber: firstNumber,
            lastNumber: last.displayNumber,
            beginTree: beginTree,
            endTree: end.tree,
            root: root
        )
    }

    /// Whether `name` is an object name Git wrote: 40 or 64 hex digits. A
    /// draft is a file on disk, and a "tree" starting with `-` would reach
    /// `git diff` as an option.
    static func isTreeName(_ name: String) -> Bool {
        (name.count == 40 || name.count == 64) && name.allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }

    /// The order a range reads its turns in: the worktree's timeline's, by
    /// when each started (`WorktreeTimeline.isInOrder`), so its first turn's
    /// begin is its earliest tree. Every slice of the timeline the changes
    /// panel lists is in this order, whatever conversations it holds.
    static func isInOrder(_ turns: [TurnSummary]) -> Bool {
        WorktreeTimeline.isInOrder(turns)
    }

    /// Each conversation once, as its turns first appear.
    private static func conversations(of turns: [TurnSummary]) -> [ConversationKey] {
        var seen: [ConversationKey] = []
        for turn in turns where !seen.contains(turn.conversation) {
            seen.append(turn.conversation)
        }
        return seen
    }

    /// Every snapshot any of the turns took is of `root`.
    private static func isOneWorkTree(_ turns: [TurnSummary], root: String) -> Bool {
        turns.allSatisfy { turn in
            [turn.beginTree, turn.endTree].allSatisfy { $0.map { $0.root == root } ?? true }
        }
    }
}
