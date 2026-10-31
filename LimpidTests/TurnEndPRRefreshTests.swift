// TurnEndPRRefreshTests.swift
// Limpid — which rows have their pull request looked up as a turn ends.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("TurnEndPRRefresh")
struct TurnEndPRRefreshTests {
    private let session = WorkspaceSession()
    private let attention = AttentionState()
    private let pane: UUID
    private let refreshed = Box()

    /// The rows looked up, in order.
    private final class Box {
        var containers: [ContainerID] = []
    }

    private let container: ContainerID

    init() throws {
        let project = session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("turn-end"), suggestedName: "test")
        container = .project(project.id)
        let leaves = session.openTab(container: container).splitTree.allLeafIDs()
        pane = try #require(leaves.first)
    }

    private func make() -> TurnEndPRRefresh {
        let refreshed = refreshed
        return TurnEndPRRefresh(attention: attention, session: session) { refreshed.containers.append($0) }
    }

    private func show(_ state: AgentState?) {
        let runtimes = state.map { [AgentRuntimePresentation.test(
            badge: AgentBadge(state: $0, runStartedAt: .distantPast, updatedAt: Date()),
            paneIDs: [pane]
        )] }
        attention.replaceRuntimes(runtimes ?? [], kind: .claude)
    }

    @Test func aRunLeavingItsTurn_looksItsRowUpOnce() {
        show(.running)
        let refresh = make()
        show(.idle)
        refresh.reconcile()
        refresh.reconcile()
        #expect(refreshed.containers == [container])
    }

    @Test func aRunThatQuitInItsTurn_looksItsRowUp() {
        show(.running)
        let refresh = make()
        show(nil)
        refresh.reconcile()
        #expect(refreshed.containers == [container])
    }

    @Test func aRunStillInItsTurn_looksNothingUp() {
        show(.running)
        let refresh = make()
        show(.compacting)
        refresh.reconcile()
        #expect(refreshed.containers.isEmpty)
    }

    @Test func aRunWaitingOnAnAnswer_hasNotEndedItsTurn() {
        show(.running)
        let refresh = make()
        show(.needsInput)
        refresh.reconcile()
        #expect(refreshed.containers.isEmpty)
    }

    @Test func aRunThatWasNeverInATurn_looksNothingUp() {
        show(.idle)
        let refresh = make()
        show(nil)
        refresh.reconcile()
        #expect(refreshed.containers.isEmpty)
    }

    /// The sync watches the attention list by itself, with no one calling it.
    @Test func aRunLeavingItsTurn_isSeenWithoutBeingAsked() async {
        show(.running)
        let refresh = make()
        show(.idle)
        await pollUntil(timeout: .seconds(30), interval: .milliseconds(1)) { !refreshed.containers.isEmpty }
        #expect(refreshed.containers == [container])
        _ = refresh
    }
}
