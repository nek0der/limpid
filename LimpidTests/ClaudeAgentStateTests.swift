// ClaudeAgentStateTests.swift
// Limpid — verifies the pure aggregation + icon / colour mapping of
// `ClaudeAgentState`. No I/O involved — the enum is a small pure
// reducer used by both L1 (container) and L2 (tab) row aggregation.

import Foundation
import Testing
@testable import Limpid

@Suite("ClaudeAgentState")
struct ClaudeAgentStateTests {
    @Test("priority follows error > needsInput > running > idle > unknown")
    func priority_ordering() {
        #expect(ClaudeAgentState.error.priority > ClaudeAgentState.needsInput.priority)
        #expect(ClaudeAgentState.needsInput.priority > ClaudeAgentState.running.priority)
        #expect(ClaudeAgentState.running.priority == ClaudeAgentState.compacting.priority)
        #expect(ClaudeAgentState.running.priority > ClaudeAgentState.idle.priority)
        #expect(ClaudeAgentState.idle.priority > ClaudeAgentState.unknown.priority)
    }

    @Test("iconName / iconColor are nil for idle and unknown")
    func icon_hiddenForQuietStates() {
        #expect(ClaudeAgentState.idle.iconName == nil)
        #expect(ClaudeAgentState.unknown.iconName == nil)
        #expect(ClaudeAgentState.idle.iconColor == nil)
        #expect(ClaudeAgentState.unknown.iconColor == nil)
    }

    @Test("iconName uses the .circle.fill family for every visible state")
    func iconName_consistentFamily() {
        for state in [ClaudeAgentState.running, .compacting, .needsInput, .error] {
            let name = try? #require(state.iconName)
            #expect(name?.hasSuffix(".circle.fill") == true)
        }
    }

    @Test("aggregateClaudeState picks the highest priority entry")
    func aggregate_picksHighestPriority() {
        let mixed: [ClaudeAgentState] = [.idle, .running, .needsInput, .error]
        #expect(mixed.aggregateClaudeState() == .error)

        let withoutError: [ClaudeAgentState] = [.idle, .needsInput, .running]
        #expect(withoutError.aggregateClaudeState() == .needsInput)

        let onlyRunning: [ClaudeAgentState] = [.idle, .running, .idle]
        #expect(onlyRunning.aggregateClaudeState() == .running)
    }

    @Test("aggregateClaudeState returns nil for all-quiet inputs")
    func aggregate_nilWhenAllQuiet() {
        #expect([ClaudeAgentState.idle, .idle].aggregateClaudeState() == nil)
        #expect([ClaudeAgentState.unknown, .idle].aggregateClaudeState() == nil)
        #expect([ClaudeAgentState]().aggregateClaudeState() == nil)
    }

    @Test("aggregateClaudeState treats compacting as running for priority")
    func aggregate_compactingFolds() {
        let mixed: [ClaudeAgentState] = [.compacting, .idle]
        #expect(mixed.aggregateClaudeState() == .compacting)
    }
}
