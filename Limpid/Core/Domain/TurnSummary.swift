// TurnSummary.swift
// Limpid — one recorded turn as the projection reports it: how it ended and what it changed.

import Foundation

/// One turn of an agent conversation, read from the record the hook helper
/// wrote (`turns/<turn-id>.turn.json`) and summarized by the projection.
///
/// Every value the helper can write and this build does not know reads as
/// `unknown` rather than failing the whole projection: a turn written by a
/// newer helper still shows, with what this build can say about it.
struct TurnSummary: Equatable, Sendable, Decodable {
    let turnID: TurnID
    let conversation: ConversationKey
    let runID: String
    let paneID: String
    /// What the person calls the turn ("T7"). Never reused within its
    /// conversation, so it is stable while the turn is shown.
    let displayNumber: Int
    /// The person's words the turn began from, on one line and cut to its
    /// first characters. For a prompt the harness wrote (`promptKind`), the
    /// head as it came, tags and all, which is never shown as it is: read
    /// both through `prompt`.
    let promptHead: String?
    /// Who wrote the prompt; `text` when the projection did not say, as an
    /// older one does not.
    let promptKind: TurnPromptKind
    let startedAt: String
    let finishedAt: String?
    /// `unknown` also for a turn whose end never came (a later turn
    /// overtook it, or its run is gone): it is not still running.
    let phase: TurnPhase
    let changes: ChangeSummary
    /// Whether a shell command, not only the agent's edit tools, changed
    /// files during the turn. Only meaningful when `changes` is `changed`.
    let hasShellChanges: Bool
    /// Untracked files over the size limit that neither snapshot holds, so
    /// the counts in `changes` may be short.
    let largeFilesSkipped: Int
    let durationSeconds: Int?
    /// The last check the turn ran, when it ran one.
    let lastCheck: CheckSummary?
    /// False for an end-only record nobody prompted: the hook saw no prompt
    /// for it (the agent stopped on its own, answering a background task; or
    /// the prompt came before this build recorded turns). History, never
    /// unread or offered for a decision.
    let hasPrompt: Bool
    /// The tree the turn began at, `nil` when the begin snapshot was not
    /// taken.
    let beginTree: SnapshotTree?
    /// The tree the turn ended at, `nil` until the end snapshot is taken or
    /// when it never was.
    let endTree: SnapshotTree?

    private enum CodingKeys: String, CodingKey {
        case turnID = "turnId"
        case conversation
        case runID = "runId"
        case paneID = "paneId"
        case displayNumber, promptHead, promptKind, startedAt, finishedAt, phase, changes, durationSeconds, lastCheck, hasPrompt, begin, end
    }

    private enum ChangeKeys: String, CodingKey {
        case hasShellChanges = "hasBashChanges"
        case largeFilesSkipped
    }

    init(from decoder: any Decoder) throws {
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
        // A check of a shape this build cannot read costs the check, not the
        // turn.
        lastCheck = (try? container.decodeIfPresent(CheckSummary.self, forKey: .lastCheck)) ?? nil
        hasPrompt = try container.decode(Bool.self, forKey: .hasPrompt)
        // Only a taken snapshot has a tree; any other state, or one this
        // build cannot read, has none.
        beginTree = (try? container.decodeIfPresent(SnapshotTree.self, forKey: .begin)) ?? nil
        endTree = (try? container.decodeIfPresent(SnapshotTree.self, forKey: .end)) ?? nil
    }

    /// The prompt the turn began from, as `TurnPromptText` words it.
    var prompt: TurnPrompt {
        TurnPrompt(kind: promptKind, head: promptHead)
    }
}

/// Who wrote the prompt a turn began from: the person, or the agent's
/// harness, which hands the hook prompts nobody typed (a background task's
/// end, a subagent's hand-back, a reminder). The hook judges it from the
/// whole prompt when the turn begins (`classify_prompt` in
/// `limpid-agent-model`); the projection judges a record from before it was
/// kept again from its head.
enum TurnPromptKind: String, Equatable, Sendable, Decodable {
    case text
    case backgroundTask
    case subagentMessage
    case injected

    /// A kind this build does not know reads as the person's words: its
    /// head is then shown as it came, which is what a build before the kind
    /// was known shows for every turn.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .text
    }
}

/// A turn's prompt as it is shown: who wrote it, and the person's words
/// when they did.
struct TurnPrompt: Equatable, Sendable {
    let kind: TurnPromptKind
    let head: String?

    init(kind: TurnPromptKind = .text, head: String?) {
        self.kind = kind
        self.head = head
    }
}

/// A snapshot the hook took: the tree object, and the work tree whose
/// repository holds it.
struct SnapshotTree: Equatable, Codable, Sendable {
    let tree: String
    let root: String

    private enum CodingKeys: String, CodingKey {
        case kind, tree, root
    }

    init(tree: String, root: String) {
        self.tree = tree
        self.root = root
    }

    /// The writer's `SnapshotStatus`, which is a tree only when `captured`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let kind = try container.decodeIfPresent(String.self, forKey: .kind), kind != "captured" {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not a taken snapshot")
        }
        tree = try container.decode(String.self, forKey: .tree)
        root = try container.decode(String.self, forKey: .root)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tree, forKey: .tree)
        try container.encode(root, forKey: .root)
    }
}

/// Where a turn stands.
enum TurnPhase: String, Equatable, Sendable, Decodable {
    case started
    case finished
    case failed
    case interrupted
    case unknown

    init(from decoder: any Decoder) throws {
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
    init(from decoder: any Decoder) throws {
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

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            command: container.decode(String.self, forKey: .command),
            isFiltered: container.decode(Bool.self, forKey: .isFiltered),
            exitCode: container.decodeIfPresent(Int.self, forKey: .exitCode)
        )
    }
}

/// One conversation's turns, in display order.
struct ConversationTurns: Equatable, Sendable, Decodable {
    let key: ConversationKey
    let turns: [TurnSummary]
}
