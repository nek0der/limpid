// DemoFixtureTests.swift
// Limpid — CI guard for the fixed demo session that powers the hero
// screenshot. We don't care about the exact contents of every tab
// here (that drifts with copy edits); we anchor on the structural
// invariants the screenshot pipeline + AGENTS.md documentation
// promise: 6 containers, 2 worktrees, an active editor split with
// initialCommands, schema-version match, and clean round-tripping
// through JSON.

import Foundation
import Testing
@testable import Limpid

@Suite("DemoFixture")
@MainActor
struct DemoFixtureTests {

    @Test("snapshot encodes at the current schema version")
    func snapshot_versionMatchesCurrent() {
        #expect(DemoFixture.snapshot.version == SessionSnapshot.currentVersion)
    }

    @Test("snapshot has 2 groups and 3 projects (Agents/Scratch + limpid/dotfiles/personal-site)")
    func snapshot_containerCounts() {
        let snap = DemoFixture.snapshot
        #expect(snap.groups.count == 2)
        #expect(snap.projects.count == 3)
    }

    @Test("limpid project carries the two demo worktrees in the documented order")
    func snapshot_limpidWorktrees() throws {
        let snap = DemoFixture.snapshot
        let limpid = try #require(
            snap.projects.first(where: { $0.id == DemoFixture.limpidProjectID })
        )
        #expect(limpid.worktrees.count == 2)
        #expect(limpid.worktrees.first?.id == DemoFixture.limpidMainWorktreeID)
        #expect(limpid.worktrees.last?.id == DemoFixture.limpidFeatWorktreeID)
        #expect(limpid.isExpanded == true)
    }

    @Test("active container is the feat worktree so the hero shot lands on it")
    func snapshot_activeContainerIsFeatWorktree() {
        let snap = DemoFixture.snapshot
        #expect(snap.activeContainerID == .worktree(
            projectID: DemoFixture.limpidProjectID,
            worktreeID: DemoFixture.limpidFeatWorktreeID
        ))
        #expect(snap.activeTabID == DemoFixture.editorTabID)
    }

    @Test("editor tab is a vertical split with initialCommands on both leaves")
    func snapshot_editorTabHasSplitWithCommands() throws {
        let snap = DemoFixture.snapshot
        let editor = try #require(snap.tabs.first(where: { $0.id == DemoFixture.editorTabID }))
        guard case let .split(data) = editor.splitTree.root else {
            Issue.record("expected editor tab to host a split")
            return
        }
        #expect(data.direction == .vertical)
        #expect(editor.initialCommands[DemoFixture.editorTopPaneID]?.isEmpty == false)
        #expect(editor.initialCommands[DemoFixture.editorBottomPaneID]?.isEmpty == false)
    }

    @Test("snapshot survives a JSON round-trip without losing state")
    func snapshot_jsonRoundTrip() throws {
        let original = DemoFixture.snapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let restored = try JSONDecoder().decode(
            SessionSnapshot.self,
            from: encoder.encode(original)
        )
        #expect(restored.version == original.version)
        #expect(restored.groups.count == original.groups.count)
        #expect(restored.projects.count == original.projects.count)
        #expect(restored.tabs.count == original.tabs.count)
        #expect(restored.activeTabID == original.activeTabID)
        #expect(restored.activeContainerID == original.activeContainerID)
    }

    @Test("isDemoActive defaults to false in the test runner (LIMPID_DEMO unset)")
    func isDemoActive_inTestRunner_isFalse() {
        // Tests aren't launched via `scripts/screenshot.sh`, so the env
        // var should not be set. Guards against the property
        // accidentally evaluating to `true` from a stale process env.
        #expect(DemoFixture.isDemoActive == false)
    }
}
