// AgentStateTests.swift
// Limpid — verifies the pure aggregation + icon / color mapping of
// `AgentState`. No I/O involved — the enum is a small pure
// reducer used by both container column and tab column row aggregation,
// shared between the Claude Code and Codex CLI integrations.

import Foundation
import Testing
@testable import Limpid

@Suite("AgentState")
struct AgentStateTests {
    @Test("priority follows error > needsInput > running > idle > unknown")
    func priority_ordering() {
        #expect(AgentState.error.priority > AgentState.needsInput.priority)
        #expect(AgentState.needsInput.priority > AgentState.running.priority)
        #expect(AgentState.running.priority == AgentState.compacting.priority)
        #expect(AgentState.running.priority > AgentState.idle.priority)
        #expect(AgentState.idle.priority > AgentState.unknown.priority)
    }

    @Test("iconName / iconColor are nil for idle and unknown")
    func icon_hiddenForQuietStates() {
        #expect(AgentState.idle.iconName == nil)
        #expect(AgentState.unknown.iconName == nil)
        #expect(AgentState.idle.iconColor == nil)
        #expect(AgentState.unknown.iconColor == nil)
    }

    @Test("iconName uses the .circle.fill family for every visible state")
    func iconName_consistentFamily() throws {
        for state in [AgentState.running, .compacting, .needsInput, .error] {
            let name = try #require(state.iconName)
            #expect(name.hasSuffix(".circle.fill"))
        }
    }

    private let en = Locale(identifier: "en")

    @Test func accessibilityLabel_description_replacesStateName() {
        #expect(AgentState.running.accessibilityLabel(isViewedFinished: false, description: "2 Running", locale: en)
            == "2 Running")
        #expect(AgentState.error.accessibilityLabel(isViewedFinished: false, locale: en) == "Error")
    }

    @Test func accessibilityLabel_viewedSuffix_onlyOnFinished() {
        #expect(AgentState.finished.accessibilityLabel(isViewedFinished: true, description: "1 Finished", locale: en)
            == "1 Finished, Viewed")
        #expect(AgentState.finished.accessibilityLabel(isViewedFinished: true, locale: en)
            == "Finished, Viewed")
        #expect(AgentState.needsInput.accessibilityLabel(isViewedFinished: true, description: "Needs input", locale: en)
            == "Needs input")
    }

    /// Spoken in the locale the row hands it, not the launch language.
    @Test func accessibilityLabel_followsTheGivenLocale() {
        let ja = Locale(identifier: "ja")
        #expect(AgentState.finished.accessibilityLabel(isViewedFinished: true, locale: ja)
            == "\(AgentState.finished.localizedLabel.resolved(in: ja))、確認済み")
        #expect(AgentState.finished.accessibilityLabel(isViewedFinished: true, locale: ja)
            != AgentState.finished.accessibilityLabel(isViewedFinished: true, locale: en))
    }

    @Test("aggregateAgentState picks the highest priority entry")
    func aggregate_picksHighestPriority() {
        let mixed: [AgentState] = [.idle, .running, .needsInput, .error]
        #expect(mixed.aggregateAgentState() == .error)

        let withoutError: [AgentState] = [.idle, .needsInput, .running]
        #expect(withoutError.aggregateAgentState() == .needsInput)

        let onlyRunning: [AgentState] = [.idle, .running, .idle]
        #expect(onlyRunning.aggregateAgentState() == .running)
    }

    @Test("aggregateAgentState returns nil for all-quiet inputs")
    func aggregate_nilWhenAllQuiet() {
        #expect([AgentState.idle, .idle].aggregateAgentState() == nil)
        #expect([AgentState.unknown, .idle].aggregateAgentState() == nil)
        #expect([AgentState]().aggregateAgentState() == nil)
    }

    @Test("aggregateAgentState treats compacting as running for priority")
    func aggregate_compactingFolds() {
        let mixed: [AgentState] = [.compacting, .idle]
        #expect(mixed.aggregateAgentState() == .compacting)
    }
}
