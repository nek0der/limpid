// AgentNotificationOutboxTests.swift
// Limpid — delayed attachment never consumes an undelivered transition.

import Foundation
import Testing
@testable import Limpid

@Suite("Agent notification outbox")
struct AgentNotificationOutboxTests {
    private let runID = UUID().uuidString
    private let paneID = UUID()

    private func runtime(_ state: AgentState, _ resolution: AgentAttachmentResolution, revision: Int = 2) -> AgentRuntimePresentation {
        AgentRuntimePresentation(
            kind: .codex,
            runID: runID,
            revision: revision,
            badge: AgentBadge(state: state, updatedAt: Date(timeIntervalSince1970: 100)),
            paneIDs: resolution == .attached ? [paneID] : [],
            tmuxLocations: [:],
            attachmentResolution: resolution
        )
    }

    @Test func delayedCompletion_deliversOnceAfterResolution() throws {
        var outbox = AgentNotificationOutbox()
        #expect(outbox.observe([runtime(.running, .unresolved, revision: 1)], now: 0, isBootstrap: true).isEmpty)
        #expect(outbox.observe([runtime(.finished, .unresolved)], now: 1).isEmpty)
        let event = try #require(outbox.observe([runtime(.finished, .attached)], now: 2).first)
        outbox.acknowledge(event)
        #expect(outbox.observe([runtime(.finished, .attached)], now: 3).isEmpty)
    }

    @Test func rejectedSink_keepsPendingUntilAcknowledged() throws {
        var outbox = AgentNotificationOutbox()
        #expect(outbox.observe([runtime(.needsInput, .unresolved)], now: 0).isEmpty)
        #expect(outbox.observe([runtime(.needsInput, .attached)], now: 1).count == 1)
        let retry = try #require(outbox.observe([runtime(.needsInput, .attached)], now: 2).first)
        outbox.acknowledge(retry)
        #expect(outbox.observe([runtime(.needsInput, .attached)], now: 3).isEmpty)
    }

    @Test func pendingEvent_supersededOrExpired_isNotDelivered() {
        var outbox = AgentNotificationOutbox()
        _ = outbox.observe([runtime(.needsInput, .unresolved)], now: 0)
        #expect(outbox.observe([runtime(.running, .attached, revision: 3)], now: 1).isEmpty)
        _ = outbox.observe([runtime(.finished, .unresolved, revision: 4)], now: 2)
        #expect(outbox.observe([runtime(.finished, .attached, revision: 4)], now: 303).isEmpty)
    }

    @Test func bootstrapAndDeliberateReattach_doNotReplay() {
        var outbox = AgentNotificationOutbox()
        #expect(outbox.observe([runtime(.finished, .attached)], now: 0, isBootstrap: true).isEmpty)
        _ = outbox.observe([runtime(.running, .detached, revision: 3)], now: 1)
        #expect(outbox.observe([runtime(.finished, .detached, revision: 4)], now: 2).isEmpty)
        #expect(outbox.observe([runtime(.finished, .attached, revision: 4)], now: 3).isEmpty)
    }
}
