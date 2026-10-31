// ChangesPanelFixture.swift
// Weir — the changes panel's turns, agents, lines, and input as its suites build them.

import Foundation
import Testing
@testable import Weir

enum ChangesPanelFixture {
    /// Turn `number` of `extras`' conversation (id `T<number>-<conversation>`),
    /// changing two files unless `changes` says otherwise.
    static func turn(
        _ number: Int,
        phase: String = "finished",
        changes: String = TurnSummaryFixture.changedFiles,
        hasPrompt: Bool = true,
        extras: TurnSummaryFixture.Extras = TurnSummaryFixture.Extras()
    ) throws -> TurnSummary {
        try TurnSummaryFixture.turn(
            "T\(number)-\(extras.conversationID)",
            phase: phase,
            changes: changes,
            hasPrompt: hasPrompt,
            number: number,
            extras: extras
        )
    }

    /// The clock writes a narrow space before AM; a test reads it as a
    /// plain one.
    static func plainSpaces(_ text: String?) -> String? {
        text?.replacingOccurrences(of: "\u{202F}", with: " ")
    }

    /// One agent holding `turns`, of the first turn's conversation.
    static func agent(_ turns: [TurnSummary]) -> ChangesPanelModel.Agent {
        ChangesPanelModel.Agent(conversation: turns.first?.conversation ?? TurnSummaryFixture.conversation, turns: turns)
    }

    /// The agents of `turns`, grouped by conversation in the order the
    /// conversations first appear.
    static func agents(_ turns: [TurnSummary]) -> [ChangesPanelModel.Agent] {
        var order: [ConversationKey] = []
        var byConversation: [ConversationKey: [TurnSummary]] = [:]
        for turn in turns {
            if byConversation[turn.conversation] == nil {
                order.append(turn.conversation)
            }
            byConversation[turn.conversation, default: []].append(turn)
        }
        return order.map { ChangesPanelModel.Agent(conversation: $0, turns: byConversation[$0] ?? []) }
    }

    /// `turn`'s conversation's viewed line, moved below it by one change,
    /// which carries `markID` and `sequence` when they are given.
    static func line(
        through turn: TurnSummary,
        at: Date = Date(),
        markID: UUID? = nil,
        sequence: Int? = nil
    ) -> (line: ViewedLine, change: ViewedLineChange?) {
        var line = ViewedLine(conversation: turn.conversation)
        let change = line.advance(to: ViewedLinePosition(turn), source: .decisionBar, markID: markID, sequence: sequence, at: at)
        return (line, change)
    }

    /// The panel with each listed line, and none for any other conversation.
    static func input(
        _ agents: [ChangesPanelModel.Agent],
        lines: [ViewedLine] = [],
        chosen: ConversationKey? = nil,
        focused: ConversationKey? = nil,
        running: [ConversationKey] = []
    ) -> ChangesPanelModel.Input {
        ChangesPanelModel.Input(agents: agents, running: running, chosen: chosen, focused: focused, line: { conversation in
            lines.first { $0.conversation == conversation }
        })
    }

    /// The turn list `content` holds, failing the test when it holds none.
    static func list(
        _ content: ChangesPanelModel.Content,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ChangesPanelModel.TurnList {
        guard case let .turns(list) = content else {
            Issue.record("expected a turn list, got \(content)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return list
    }
}
