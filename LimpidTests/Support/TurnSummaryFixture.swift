// TurnSummaryFixture.swift
// Limpid — turn summaries as the projection reports them, for tests.

import Foundation
import Testing
@testable import Limpid

enum TurnSummaryFixture {
    static let conversation = ConversationKey(provider: .claude, conversationID: "s1", isFallback: false)

    /// Another conversation, for a test of several side by side.
    static func conversation(_ id: String, provider: AgentKind = .claude) -> ConversationKey {
        ConversationKey(provider: provider, conversationID: id, isFallback: false)
    }

    /// What a turn ended with and ran, beside its identity.
    struct Extras {
        var beginTree: SnapshotTree?
        var finishedAt: String?
        /// The record's `lastCheck`, as JSON.
        var check: String?
        /// The record's `checks`, as JSON.
        var checks: String?
        var checkCount: Int?
        var failureCount: Int?
        var areChecksPartial: Bool?
        /// The record's `usage`, as JSON.
        var usage: String?
        /// The prompt's first characters, as the record keeps them.
        var promptHead: String?
        /// Who wrote the prompt, as the projection says it; `nil` leaves
        /// the key out, as a projection from before it was kept does.
        var promptKind: TurnPromptKind?
        /// The projection's `promptKind` as raw JSON, for a value this build
        /// does not know or one of the wrong shape. Wins over `promptKind`.
        var promptKindJSON: String?
        /// How long the turn ran.
        var durationSeconds: Int?
        /// The conversation, when not `conversation`'s.
        var conversationID = "s1"
        /// The run the turn was recorded in.
        var runID = "R"
        /// When the turn started, as the record writes it.
        var startedAt = "2026-10-12T00:00:00Z"
    }

    /// A turn of `conversation`, decoded from the JSON the projection sends
    /// so the test goes through the same reader as the app.
    static func turn(
        _ id: String,
        phase: String = "finished",
        changes: String = #"{"kind":"unchanged"}"#,
        hasPrompt: Bool = true,
        number: Int = 1,
        endTree: SnapshotTree? = nil,
        endStatus: String? = #"{"kind":"pending"}"#,
        extras: Extras = Extras()
    ) throws -> TurnSummary {
        // A taken tree, else the status as given; `nil` leaves the key out,
        // as a record from before the end snapshot was reported does.
        let end = endTree.map(captured) ?? endStatus
        var fields = ""
        if let end {
            fields += #","end":\#(end)"#
        }
        if let begin = extras.beginTree {
            fields += #","begin":\#(captured(begin))"#
        }
        if let finishedAt = extras.finishedAt {
            fields += #","finishedAt":"\#(finishedAt)""#
        }
        if let check = extras.check {
            fields += #","lastCheck":\#(check)"#
        }
        if let checks = extras.checks {
            fields += #","checks":\#(checks)"#
        }
        if let checkCount = extras.checkCount {
            fields += #","checkCount":\#(checkCount)"#
        }
        if let failureCount = extras.failureCount {
            fields += #","failureCount":\#(failureCount)"#
        }
        if let areChecksPartial = extras.areChecksPartial {
            fields += #","areChecksPartial":\#(areChecksPartial)"#
        }
        if let usage = extras.usage {
            fields += #","usage":\#(usage)"#
        }
        if let seconds = extras.durationSeconds {
            fields += #","durationSeconds":\#(seconds)"#
        }
        if let promptHead = extras.promptHead {
            guard let encoded = try String(bytes: JSONEncoder().encode(promptHead), encoding: .utf8) else {
                throw CocoaError(.coderInvalidValue)
            }
            fields += #","promptHead":\#(encoded)"#
        }
        if let promptKind = extras.promptKindJSON ?? extras.promptKind.map({ #""\#($0.rawValue)""# }) {
            fields += #","promptKind":\#(promptKind)"#
        }
        let json = """
        {"turnId":"\(id)","conversation":{"provider":"claude","conversationId":"\(extras.conversationID)","isFallback":false},
         "runId":"\(extras.runID)","paneId":"P","displayNumber":\(number),"startedAt":"\(extras.startedAt)",
         "phase":"\(phase)","changes":\(changes),"hasPrompt":\(hasPrompt)\(fields)}
        """
        return try JSONDecoder().decode(TurnSummary.self, from: Data(json.utf8))
    }

    private static func captured(_ tree: SnapshotTree) -> String {
        #"{"kind":"captured","tree":"\#(tree.tree)","root":"\#(tree.root)"}"#
    }

    /// A tree name Git could have written (40 hex digits), told apart by
    /// `kind` (a hex letter) and `number`.
    static func tree(_ kind: Character, _ number: Int) -> String {
        let suffix = String(number)
        return String(repeating: kind, count: 40 - suffix.count) + suffix
    }

    static let changedFiles = #"{"kind":"changed","files":2,"added":3,"removed":1,"hasBashChanges":false}"#

    /// `seconds` into 2026-10-12, as a record writes a time.
    static func stamp(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return String(format: "2026-10-12T%02d:%02d:%02dZ", minutes / 60, minutes % 60, seconds % 60)
    }

    /// Turn `number` of `conversation` (id `T<number>-<conversation>`), in
    /// `root`, that started at `start` and ended at `end`, both seconds into
    /// 2026-10-12 (`stamp`); `end` nil leaves the end time out, as a turn
    /// still running has none. Its trees are named by its number and times,
    /// so two turns end at one tree only when they share a number, an end,
    /// and `endKind`: give two conversations' turns the same `endKind` to
    /// end them at one tree.
    static func timed(
        _ number: Int,
        conversation: String = "s1",
        start: Int,
        end: Int?,
        phase: String = "finished",
        changes: String = changedFiles,
        hasBegin: Bool = true,
        hasEnd: Bool = true,
        endKind: Character = "e",
        root: String = "/repo"
    ) throws -> TurnSummary {
        var extras = Extras()
        extras.conversationID = conversation
        extras.startedAt = stamp(start)
        extras.finishedAt = end.map(stamp)
        if hasBegin {
            extras.beginTree = SnapshotTree(tree: tree("b", number * 1_000_000 + start), root: root)
        }
        let endTree = hasEnd ? end.map { SnapshotTree(tree: tree(endKind, number * 1_000_000 + $0), root: root) } : nil
        return try turn(
            "T\(number)-\(conversation)",
            phase: phase,
            changes: changes,
            number: number,
            endTree: endTree,
            extras: extras
        )
    }

    /// Turn `id` (`T<number>` when nil) of the fixture's conversation,
    /// finished, changing two files, with its begin and end trees in
    /// `/repo` named by `number`: the turn a review reads.
    static func recordedTurn(_ id: String? = nil, number: Int = 1) throws -> TurnSummary {
        try turn(
            id ?? "T\(number)",
            changes: changedFiles,
            number: number,
            endTree: SnapshotTree(tree: tree("e", number), root: "/repo"),
            extras: .init(beginTree: SnapshotTree(tree: tree("b", number), root: "/repo"))
        )
    }

    /// The fixed range of `recordedTurn(id, number:)` alone.
    static func range(
        _ id: String? = nil,
        number: Int = 1,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ReviewTurnRange {
        try #require(ReviewTurnRange(turns: [recordedTurn(id, number: number)]), sourceLocation: sourceLocation)
    }
}
