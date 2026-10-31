// TurnSummary.swift
// Weir — one recorded turn as the projection reports it: how it ended and what it changed.

import Foundation

/// One turn of an agent conversation, read from the record the hook helper
/// wrote (`turns/<turn-id>.turn.json`) and summarized by the projection.
///
/// Every value the helper can write and this build does not know reads as
/// `unknown` rather than failing the whole projection: a turn written by a
/// newer helper still shows, with what this build can say about it.
package struct TurnSummary: Equatable, Sendable, Decodable {
    package let turnID: TurnID
    package let conversation: ConversationKey
    package let runID: String
    package let paneID: String
    /// What the person calls the turn ("T7"). Never reused within its
    /// conversation, so it is stable while the turn is shown.
    package let displayNumber: Int
    /// The person's words the turn began from, on one line and cut to its
    /// first characters. For a prompt the harness wrote (`promptKind`), the
    /// head as it came, tags and all, which is never shown as it is: read
    /// both through `prompt`.
    let promptHead: String?
    /// Who wrote the prompt; `text` when the projection did not say, as an
    /// older one does not.
    package let promptKind: TurnPromptKind
    /// What the agent said as the turn ended: its reply's first paragraph
    /// on one line, which the writer cuts to 400 characters. Optional
    /// because a turn no stop ended has none, nor does a reply of code
    /// alone or a record from before it was kept; read it through `reply`.
    let replyHead: String?
    /// The conversation's title when the turn began or last ended: the
    /// provider's session title, else the one it generated. Kept on the
    /// turn so a closed conversation whose run is gone still has a name;
    /// the newest turn's title is the one that names the conversation.
    /// Optional because the provider had not named the conversation yet, or
    /// the record is from before the title was kept.
    package let conversationTitle: String?
    package let startedAt: String
    package let finishedAt: String?
    /// `unknown` also for a turn whose end never came (a later turn
    /// overtook it, or its run is gone): it is not still running.
    package let phase: TurnPhase
    package let changes: ChangeSummary
    /// Whether a shell command, not only the agent's edit tools, changed
    /// files during the turn. Only meaningful when `changes` is `changed`.
    package let hasShellChanges: Bool
    /// Untracked files over the size limit that neither snapshot holds, so
    /// the counts in `changes` may be short.
    package let largeFilesSkipped: Int
    package let durationSeconds: Int?
    /// The last check the turn ran, when it ran one, with how many of the
    /// checks before it failed.
    package let lastCheck: CheckSummary?
    /// The turn's last checks in the order they ran, as many as the record
    /// keeps (`MAX_CHECK_MARKS` in `weir-agent-model`).
    package let checks: [CheckMark]
    /// How many checks the turn ran, those `checks` no longer holds
    /// included.
    package let checkCount: Int
    /// How many of them failed, those `checks` no longer holds included.
    package let failureCount: Int
    /// Whether the turn may have run checks the counts leave out: they were
    /// read at its end from a part of the agent's transcript that no longer
    /// held the turn's start.
    package let areChecksPartial: Bool
    /// The actions the provider refused in the turn without asking the
    /// person (Claude's auto mode), the first ones the record keeps
    /// (`MAX_DENIED_ACTIONS` in `weir-agent-model`).
    package let deniedActions: [DeniedAction]
    /// How many it refused, those `deniedActions` does not hold included.
    package let deniedCount: Int
    /// What the turn used, `nil` until it ended, or when the agent's
    /// transcript did not say.
    package let usage: TurnUsage?
    /// False for an end-only record nobody prompted: the hook saw no prompt
    /// for it (the agent stopped on its own, answering a background task; or
    /// the prompt came before this build recorded turns). History, never
    /// unread or offered for a decision.
    package let hasPrompt: Bool
    /// The tree the turn began at, `nil` when the begin snapshot was not
    /// taken.
    package let beginTree: SnapshotTree?
    /// The tree the turn ended at, `nil` until the end snapshot is taken or
    /// when it never was.
    package let endTree: SnapshotTree?

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case conversation
        case runID = "runId"
        case paneID = "paneId"
        case displayNumber, promptHead, promptKind, replyHead, conversationTitle, startedAt, finishedAt, phase, changes, durationSeconds,
             lastCheck, checks, checkCount, failureCount, areChecksPartial, deniedActions, deniedCount, usage, hasPrompt, begin, end
    }

    private enum ChangeKeys: String, CodingKey {
        case hasShellChanges = "hasBashChanges"
        case largeFilesSkipped
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try container.decode(TurnID.self, forKey: .turnID)
        conversation = try container.decode(ConversationKey.self, forKey: .conversation)
        runID = try container.decode(String.self, forKey: .runID)
        paneID = try container.decode(String.self, forKey: .paneID)
        displayNumber = try container.decode(Int.self, forKey: .displayNumber)
        promptHead = try container.decodeIfPresent(String.self, forKey: .promptHead)
        // A kind of a shape this build cannot read costs the kind, not the
        // turn.
        promptKind = (try? container.decodeIfPresent(TurnPromptKind.self, forKey: .promptKind)) ?? .text
        replyHead = try container.decodeIfPresent(String.self, forKey: .replyHead)
        conversationTitle = try container.decodeIfPresent(String.self, forKey: .conversationTitle)
        startedAt = try container.decode(String.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(String.self, forKey: .finishedAt)
        phase = try container.decode(TurnPhase.self, forKey: .phase)
        changes = try container.decode(ChangeSummary.self, forKey: .changes)
        // The writer keeps these beside the counts; this build's
        // `ChangeSummary` holds what every reader of a change needs.
        let details = try container.nestedContainer(keyedBy: ChangeKeys.self, forKey: .changes)
        hasShellChanges = try details.decodeIfPresent(Bool.self, forKey: .hasShellChanges) ?? false
        largeFilesSkipped = try details.decodeIfPresent(Int.self, forKey: .largeFilesSkipped) ?? 0
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        // Checks, or a usage, of a shape this build cannot read cost those
        // facts, not the turn: a list of marks that does not read is lost
        // whole, and the card shows the last check alone, as a record from
        // before the marks were kept.
        let checks = (try? container.decodeIfPresent([CheckMark].self, forKey: .checks)) ?? []
        self.checks = checks
        // Never fewer than the marks held, nor than the one last check a
        // record from before the count was kept holds.
        let hasLastCheck = container.contains(.lastCheck)
        checkCount = max((try? container.decodeIfPresent(Int.self, forKey: .checkCount)) ?? 0, checks.count, hasLastCheck ? 1 : 0)
        // Never fewer than the failed runs the marks hold, so the count and
        // the marks never disagree.
        let failureCount = max((try? container.decodeIfPresent(Int.self, forKey: .failureCount)) ?? 0, checks.count(where: \.hasFailed))
        self.failureCount = failureCount
        areChecksPartial = (try? container.decodeIfPresent(Bool.self, forKey: .areChecksPartial)) ?? false
        lastCheck = ((try? container.decodeIfPresent(CheckSummary.self, forKey: .lastCheck)) ?? nil).map { check in
            CheckSummary(
                command: check.command,
                isFiltered: check.isFiltered,
                exitCode: check.exitCode,
                earlierFailures: max(0, failureCount - (check.hasFailed ? 1 : 0))
            )
        }
        // As with checks: a list that does not read costs the list, not the
        // turn, and the count is never fewer than the list holds.
        let deniedActions = (try? container.decodeIfPresent([DeniedAction].self, forKey: .deniedActions)) ?? []
        self.deniedActions = deniedActions
        deniedCount = max((try? container.decodeIfPresent(Int.self, forKey: .deniedCount)) ?? 0, deniedActions.count)
        usage = (try? container.decodeIfPresent(TurnUsage.self, forKey: .usage)) ?? nil
        hasPrompt = try container.decode(Bool.self, forKey: .hasPrompt)
        // Only a taken snapshot has a tree; any other state, or one this
        // build cannot read, has none.
        beginTree = (try? container.decodeIfPresent(SnapshotTree.self, forKey: .begin)) ?? nil
        endTree = (try? container.decodeIfPresent(SnapshotTree.self, forKey: .end)) ?? nil
    }

    /// The prompt the turn began from, as `TurnPromptText` words it.
    package var prompt: TurnPrompt {
        TurnPrompt(kind: promptKind, head: promptHead)
    }

    /// The reply the turn ended with, only while it reads as finished: a
    /// turn that then failed or was overtaken ended on something else, and
    /// its reply would not say what came of it.
    package var reply: String? {
        guard phase == .finished, let replyHead, !replyHead.isEmpty else { return nil }
        return replyHead
    }
}

/// Who wrote the prompt a turn began from: the person, or the agent's
/// harness, which hands the hook prompts nobody typed (a background task's
/// end, a subagent's hand-back, a reminder). The hook judges it from the
/// whole prompt when the turn begins (`classify_prompt` in
/// `weir-agent-model`); the projection judges a record from before it was
/// kept again from its head. A turn Codex began itself for the goal the
/// person set (`/goal`) has no prompt; the hook names it `goal`, with the
/// goal's objective as its head.
package enum TurnPromptKind: String, Equatable, Sendable, Decodable {
    case text
    case backgroundTask
    case subagentMessage
    case injected
    case goal

    /// The head is the person's own words: what they typed, or the goal
    /// they set. They name a conversation and are cut for a menu line; the
    /// harness's prompts do neither.
    package var isThePersonsWords: Bool {
        self == .text || self == .goal
    }

    /// A kind this build does not know reads as the person's words: its
    /// head is then shown as it came, which is what a build before the kind
    /// was known shows for every turn.
    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .text
    }
}

/// A turn's prompt as it is shown: who wrote it, and the person's words
/// when they did.
package struct TurnPrompt: Equatable, Sendable {
    package let kind: TurnPromptKind
    package let head: String?

    package init(kind: TurnPromptKind = .text, head: String?) {
        self.kind = kind
        self.head = head
    }
}

/// A snapshot the hook took: the tree object, and the work tree whose
/// repository holds it.
package struct SnapshotTree: Equatable, Codable, Sendable {
    package let tree: String
    package let root: String

    private enum CodingKeys: String, CodingKey {
        case kind, tree, root
    }

    package init(tree: String, root: String) {
        self.tree = tree
        self.root = root
    }

    /// The writer's `SnapshotStatus`, which is a tree only when `captured`.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind), kind != "captured" {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not a taken snapshot")
        }
        tree = try container.decode(String.self, forKey: .tree)
        root = try container.decode(String.self, forKey: .root)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tree, forKey: .tree)
        try container.encode(root, forKey: .root)
    }
}

/// Where a turn stands.
package enum TurnPhase: String, Equatable, Sendable, Decodable {
    case started
    case finished
    case failed
    case interrupted
    case unknown

    package init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

extension ChangeSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case kind, files, added, removed, reason
    }

    /// The writer's `ChangeSummary` (`kind` plus its fields). A kind this
    /// build does not know reads as `unknown`, which the interface treats as
    /// "not yet known", never as unchanged.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "pending":
            self = .pending
        case "changed":
            self = try .changed(
                files: container.decode(Int.self, forKey: .files),
                added: container.decode(Int.self, forKey: .added),
                removed: container.decode(Int.self, forKey: .removed)
            )
        case "unchanged":
            self = .unchanged
        case "unavailable":
            self = try .unavailable(reason: container.decode(String.self, forKey: .reason))
        default:
            self = .unknown
        }
    }
}

extension CheckSummary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case command, exitCode, isFiltered
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            command: container.decode(String.self, forKey: .command),
            isFiltered: container.decode(Bool.self, forKey: .isFiltered),
            exitCode: container.decodeIfPresent(Int.self, forKey: .exitCode)
        )
    }
}

/// An action the provider refused in a turn without asking the person: what
/// the agent tried, and why, both in the provider's words.
package struct DeniedAction: Equatable, Sendable, Decodable {
    package let action: String
    package let reason: String
}

/// One check run of a turn: how it exited, and whether it ran only part of
/// the suite.
package struct CheckMark: Equatable, Sendable, Decodable {
    /// `nil` when the status was not the check's own (`CheckSummary`).
    package let exitCode: Int?
    package let isFiltered: Bool

    package init(exitCode: Int?, isFiltered: Bool) {
        self.exitCode = exitCode
        self.isFiltered = isFiltered
    }

    private enum CodingKeys: String, CodingKey {
        case exitCode, isFiltered
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        // Lenient where `CheckSummary` is not: one mark that does not read
        // would cost the whole list.
        isFiltered = try container.decodeIfPresent(Bool.self, forKey: .isFiltered) ?? false
    }

    /// The check's own exit code says it failed, as `CheckSummary.hasFailed`.
    package var hasFailed: Bool {
        exitCode.map { $0 != 0 } ?? false
    }
}

/// The tokens a turn's requests used, as the agent's transcript recorded
/// them, its subagents' included where the transcript names their own
/// (`TurnUsage` in `weir-agent-model`).
/// Counted, never priced: most people run the agents on a plan.
package struct TurnUsage: Equatable, Sendable, Decodable {
    /// Input sent fresh, neither read from nor written to the prompt cache.
    package let inputTokens: Int
    package let cacheWriteTokens: Int
    package let cacheReadTokens: Int
    package let outputTokens: Int
    /// Part of the turn could not be read, so the counts are short.
    package let isPartial: Bool

    package init(inputTokens: Int, cacheWriteTokens: Int, cacheReadTokens: Int, outputTokens: Int, isPartial: Bool = false) {
        self.inputTokens = inputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.isPartial = isPartial
    }

    /// What `turns` used together, `nil` when none has a count. The total is
    /// partial if a turn's own count is, or if a turn ended without one, as
    /// one recorded before we kept usage does. A running turn has no count
    /// until it ends, so it does not make the total partial.
    package static func total(of turns: [TurnSummary]) -> Self? {
        let usages = turns.compactMap(\.usage)
        guard !usages.isEmpty else { return nil }
        return Self(
            inputTokens: usages.reduce(0) { $0 + $1.inputTokens },
            cacheWriteTokens: usages.reduce(0) { $0 + $1.cacheWriteTokens },
            cacheReadTokens: usages.reduce(0) { $0 + $1.cacheReadTokens },
            outputTokens: usages.reduce(0) { $0 + $1.outputTokens },
            isPartial: usages.contains(where: \.isPartial)
                || turns.contains { $0.usage == nil && $0.phase != .started }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, cacheWriteTokens, cacheReadTokens, outputTokens, isPartial
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try container.decode(Int.self, forKey: .inputTokens)
        cacheWriteTokens = try container.decode(Int.self, forKey: .cacheWriteTokens)
        cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
        outputTokens = try container.decode(Int.self, forKey: .outputTokens)
        isPartial = try container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
    }
}

/// One conversation's turns, in display order.
package struct ConversationTurns: Equatable, Sendable, Decodable {
    package let key: ConversationKey
    package let turns: [TurnSummary]

    package init(
        key: ConversationKey,
        turns: [TurnSummary]
    ) {
        self.key = key
        self.turns = turns
    }
}
