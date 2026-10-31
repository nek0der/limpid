// DemoFixture+StagedTurns.swift
// Limpid — the turns the demo stages for one conversation.

import Foundation
import Testing
@testable import Limpid

extension DemoFixture {
    static func stagedTurns(of conversation: ConversationKey, now: Date = Date()) throws -> [TurnSummary] {
        try #require(conversations(now: now).first { $0.key == conversation }?.turns)
    }
}
