// TabActionsMergePaneIntoTabTests.swift
// Limpid — exercises `TabActions.mergePaneIntoTab` across its branches:
// source == target, lone-pane source (closes the source tab), multi-pane
// source (keeps it alive), and per-pane state migration.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("TabActions.mergePaneIntoTab")
struct TabActionsMergePaneIntoTabTests {

    // Tuple returns keep call-site destructuring tight; the 4-member
    // tuple ceiling is fine here for the same reason `WindowSessionFixture`
    // suppresses the lint above its similar fixture builders.
    // swiftlint:disable large_tuple

    /// Helper: build a session with two loose tabs and return both. The
    /// source tab has one extra pane spawned via `TabActions.split` so
    /// the default test case exercises the multi-leaf branch; the
    /// caller can trim the source down to a lone pane for the
    /// auto-close branch.
    ///
    /// Throws via `#require` so a broken invariant (e.g. `openTab`
    /// returning an empty splitTree) surfaces with a clear "Required
    /// value was nil" error pointed at the failing line, instead of
    /// the bare `Fatal error: Unexpectedly found nil` a force-unwrap
    /// would produce.
    private static func sessionWithSourceAndTarget(
        sourcePanes: Int = 2
    ) throws -> (session: WindowSession, source: Tab, target: Tab, movedPane: UUID) {
        let session = WindowSession()
        let source = session.openTab(container: .loose)
        let target = session.openTab(container: .loose)
        session.setActiveTab(source.id)
        // Add panes to the source tab via the same `split` action the UI
        // uses, so the splitTree shape mirrors what the user would see.
        for _ in 1..<sourcePanes {
            PaneActions.split(session, direction: .horizontal)
        }
        // Pick the pane that became focused after the splits — that's
        // the one a real drag would have picked up first.
        let live = try #require(session.tab(source.id))
        let movedPane = try #require(
            live.splitTree.focusedLeafID ?? live.splitTree.allLeafIDs().last
        )
        return (session, live, target, movedPane)
    }

    // swiftlint:enable large_tuple

    @Test("source == target is a no-op")
    func sourceEqualsTarget_isNoOp() throws {
        let (session, source, _, paneID) = try Self.sessionWithSourceAndTarget()
        let sourceLeafCountBefore = source.splitTree.allLeafIDs().count

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: source.id)

        let sourceAfter = session.tab(source.id)
        #expect(sourceAfter?.splitTree.allLeafIDs().count == sourceLeafCountBefore)
        #expect(sourceAfter?.splitTree.contains(leafID: paneID) == true)
    }

    @Test("multi-leaf source: pane lands in target, source keeps its sibling")
    func multiLeafSource_keepsSourceAlive() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget(sourcePanes: 2)

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        let sourceAfter = try #require(session.tab(source.id))
        let targetAfter = try #require(session.tab(target.id))
        #expect(!sourceAfter.splitTree.contains(leafID: paneID))
        #expect(targetAfter.splitTree.contains(leafID: paneID))
        // Target had 1 leaf, now 2 (the original + the merged-in pane).
        #expect(targetAfter.splitTree.allLeafIDs().count == 2)
        // Source retains exactly one leaf (the sibling).
        #expect(sourceAfter.splitTree.allLeafIDs().count == 1)
    }

    @Test("lone-pane source: empty source tab is closed")
    func singleLeafSource_closesSourceTab() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget(sourcePanes: 1)

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        #expect(session.tab(source.id) == nil)
        let targetAfter = try #require(session.tab(target.id))
        #expect(targetAfter.splitTree.contains(leafID: paneID))
        #expect(targetAfter.splitTree.allLeafIDs().count == 2)
    }

    @Test("moved pane becomes the focused leaf in the target tab")
    func movedPane_becomesFocused() throws {
        let (session, _, target, paneID) = try Self.sessionWithSourceAndTarget()

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        let targetAfter = try #require(session.tab(target.id))
        #expect(targetAfter.splitTree.focusedLeafID == paneID)
        #expect(session.activeTabID == target.id)
    }

    @Test("per-pane state (all 7 Tab-level dictionaries) migrates with the leaf")
    func perPaneState_migratesWithLeaf() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget()
        // Plant a distinct value in every per-pane state dictionary on
        // the source side so we can verify each one lands on the target
        // — a typo like
        // `if let s = sourceTab.codexBadges[paneID] { newTab.claudeAgentBadges[paneID] = s }`
        // would survive type-checking, so the only safeguard is an
        // explicit assertion per field.
        let paneState = PaneState(unreadCount: 7)
        let scrollback = "/tmp/scrollback-\(paneID).vt"
        let initial = "echo hello"
        let claudeSession = ClaudeSessionInfo(sessionId: "claude-\(paneID)", cwd: "/tmp/claude")
        let codexSession = CodexSessionInfo(sessionId: "codex-\(paneID)", cwd: "/tmp/codex")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeBadge = ClaudeAgentBadge(
            state: .running,
            detail: "claude-detail",
            runStartedAt: now,
            contextTokens: 1234,
            updatedAt: now,
            lastPrompt: "claude prompt"
        )
        let codexBadge = CodexAgentBadge(
            state: .running,
            detail: "codex-detail",
            runStartedAt: now,
            contextTokens: 5678,
            updatedAt: now,
            lastPrompt: "codex prompt"
        )
        let updated = session.update(source.id) { t in
            t.paneStates[paneID] = paneState
            t.scrollbackPaths[paneID] = scrollback
            t.initialCommands[paneID] = initial
            t.claudeSessions[paneID] = claudeSession
            t.codexSessions[paneID] = codexSession
            t.claudeAgentBadges[paneID] = claudeBadge
            t.codexAgentBadges[paneID] = codexBadge
        }
        #expect(updated, "Setting per-pane state should mutate the tab")

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        let sourceAfter = session.tab(source.id)
        let targetAfter = try #require(session.tab(target.id))
        // Migrated values present on target — each field checked
        // explicitly so a cross-field bug at the action site shows up
        // as a precise diff rather than a vague "something is wrong".
        #expect(targetAfter.paneStates[paneID] == paneState)
        #expect(targetAfter.scrollbackPaths[paneID] == scrollback)
        #expect(targetAfter.initialCommands[paneID] == initial)
        #expect(targetAfter.claudeSessions[paneID] == claudeSession)
        #expect(targetAfter.codexSessions[paneID] == codexSession)
        #expect(targetAfter.claudeAgentBadges[paneID] == claudeBadge)
        #expect(targetAfter.codexAgentBadges[paneID] == codexBadge)
        // And the source side has been swept (or the whole tab closed
        // when it was a lone-pane source).
        #expect(sourceAfter?.paneStates[paneID] == nil)
        #expect(sourceAfter?.scrollbackPaths[paneID] == nil)
        #expect(sourceAfter?.initialCommands[paneID] == nil)
        #expect(sourceAfter?.claudeSessions[paneID] == nil)
        #expect(sourceAfter?.codexSessions[paneID] == nil)
        #expect(sourceAfter?.claudeAgentBadges[paneID] == nil)
        #expect(sourceAfter?.codexAgentBadges[paneID] == nil)
    }

    @Test("zoom on the moved leaf is cleared from the source tab")
    func zoomedMovedLeaf_clearsSourceZoom() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget()
        _ = session.update(source.id) { t in t.zoomedLeafID = paneID }
        #expect(session.tab(source.id)?.zoomedLeafID == paneID)

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        // Source kept the sibling but the zoom anchor is gone, so a
        // future tab switch back doesn't try to zoom a leaf that's no
        // longer in this tree.
        #expect(session.tab(source.id)?.zoomedLeafID == nil)
    }
}
