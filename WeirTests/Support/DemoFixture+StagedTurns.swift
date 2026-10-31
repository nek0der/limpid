// DemoFixture+StagedTurns.swift
// Weir — the turns the demo stages for one conversation.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

extension DemoFixture {
    static func stagedTurns(of conversation: ConversationKey, now: Date = Date()) throws -> [TurnSummary] {
        try #require(conversations(now: now).first { $0.key == conversation }?.turns)
    }
}
