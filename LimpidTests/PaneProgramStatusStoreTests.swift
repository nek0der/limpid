// PaneProgramStatusStoreTests.swift
// Limpid — which OSC 7501 reports a pane keeps, and which titles they leave off its tab.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Pane program status")
struct PaneProgramStatusStoreTests {
    private static let pane = UUID(uuidString: "11111111-1111-4111-8111-111111111111") ?? UUID()
    private static let at = Date(timeIntervalSince1970: 1_800_000_000)

    /// A store that knows Claude Code as an agent and counts its changes.
    @MainActor
    private final class Scene {
        let store = PaneProgramStatusStore(now: { PaneProgramStatusStoreTests.at })
        var changes = 0

        init() {
            store.agentApps = ["claude-code"]
            store.onChange = { [unowned self] in changes += 1 }
        }

        func report(_ state: ProgramStatusReport.State, app: String = "claude-code", recordID: String = "") {
            store.receive(ProgramStatusReport(app: app, recordID: recordID, state: state), in: PaneProgramStatusStoreTests.pane)
        }
    }

    @Test func aReport_isWhatTheProjectionReads() {
        let scene = Scene()
        scene.report(.blocked)
        #expect(scene.store.projectionInput == [
            Self.pane.uuidString: AgentProjectionProgramStatus(
                app: "claude-code",
                state: "blocked",
                observedAt: AgentDateParsing.formatISO8601(Self.at)
            )
        ])
        #expect(scene.changes == 1)

        // The same state again changes nothing the projection reads.
        scene.report(.blocked)
        #expect(scene.changes == 1)
        scene.report(.idle)
        #expect(scene.store.statuses[Self.pane]?.state == .idle)
        #expect(scene.changes == 2)
    }

    @Test func aReportAboutPartOfTheWork_isNotKept() {
        let scene = Scene()
        scene.report(.working, recordID: "deploy/us-east")
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.changes == 0)
    }

    @Test func clear_removesThePanesStatus() {
        let scene = Scene()
        scene.report(.idle)
        scene.report(.clear)
        #expect(scene.store.statuses.isEmpty)
        #expect(scene.store.projectionInput.isEmpty)
        #expect(scene.changes == 2)
    }

    @Test func anotherProgramsReport_isKept_butRequestsNoPass() {
        let scene = Scene()
        scene.report(.working, app: "cargo")
        #expect(scene.store.statuses[Self.pane]?.app == "cargo")
        #expect(scene.changes == 0)
    }

    @Test func whileAnAgentReports_everyTitleIsLeftOff() {
        let scene = Scene()
        #expect(!scene.store.silencesTitle("~/dev/project", from: Self.pane), "no report, no change")
        scene.report(.idle)
        #expect(scene.store.silencesTitle("Claude Code", from: Self.pane))
        #expect(scene.store.silencesTitle("", from: Self.pane))
    }

    @Test func anotherProgramsTitles_areLetThrough() {
        let scene = Scene()
        scene.report(.working, app: "cargo")
        #expect(!scene.store.silencesTitle("cargo build", from: Self.pane))
    }

    @Test func afterTheAgentClears_onlyItsEmptyExitTitleIsLeftOff() {
        let scene = Scene()
        scene.report(.idle)
        scene.report(.clear)
        // Claude Code clears its title on its way out.
        #expect(scene.store.silencesTitle("", from: Self.pane))
        // The shell's next title is let through, and the one after that too.
        #expect(!scene.store.silencesTitle("~/dev/project", from: Self.pane))
        #expect(!scene.store.silencesTitle("", from: Self.pane))
    }

    @Test func aPaneWhoseProgramIsGone_isForgotten() {
        let scene = Scene()
        scene.report(.blocked)
        scene.store.forget(Self.pane)
        #expect(scene.store.statuses.isEmpty)
        #expect(!scene.store.silencesTitle("", from: Self.pane))
        #expect(scene.changes == 2)
    }
}
