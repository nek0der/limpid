// TabActionsMovePaneTests.swift
// Limpid — a pane moved into another tab or a tab of its own, and everything of the pane's that goes with it.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("TabActions moving a pane")
struct TabActionsMovePaneTests {

    // A tuple keeps the call sites' destructuring, as the fixtures' do.
    // swiftlint:disable large_tuple

    /// Two loose tabs, the source in front and split in two through the
    /// action the UI uses, so the default case moves a pane out of a tab
    /// that keeps another; `sourcePanes: 1` leaves the source a lone pane.
    /// The pane moved is the one focused after the splits, the one a drag
    /// would pick up first.
    private static func sessionWithSourceAndTarget(
        sourcePanes: Int = 2
    ) throws -> (session: WorkspaceSession, source: Tab, target: Tab, movedPane: UUID) {
        let (session, target, _, source, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        session.setActiveTab(source.id)
        for _ in 1..<sourcePanes {
            PaneActions.split(session, direction: .horizontal)
        }
        let live = try #require(session.tab(source.id))
        let movedPane = try #require(live.splitTree.focusedLeafID ?? live.splitTree.allLeafIDs().last)
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
        #expect(session.primarySelection.activeTabID == target.id)
    }

    @Test("every per-pane state of the tab migrates with the leaf")
    func perPaneState_migratesWithLeaf() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget()
        // A distinct value in every per-pane state dictionary on the source
        // side, each checked on the target: a value written under another
        // provider's or field's key type-checks, so only a check per field
        // finds it.
        let paneState = PaneState(unreadCount: 7, name: "tests")
        let scrollback = "/tmp/scrollback-\(paneID).vt"
        let initial = "echo hello"
        let claudeSession = AgentSessionInfo(sessionId: "claude-\(paneID)", cwd: "/tmp/claude")
        let codexSession = AgentSessionInfo(sessionId: "codex-\(paneID)", cwd: "/tmp/codex")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let claudeBadge = AgentBadge(
            state: .running,
            detail: "claude-detail",
            runStartedAt: now,
            updatedAt: now,
            lastPrompt: "claude prompt"
        )
        let codexBadge = AgentBadge(
            state: .running,
            detail: "codex-detail",
            runStartedAt: now,
            updatedAt: now,
            lastPrompt: "codex prompt"
        )
        let tmuxBinding = TmuxBinding(
            socketPath: "/private/tmp/tmux-501/default",
            sessionID: "$4",
            sessionName: "moved"
        )
        let updated = session.update(source.id) { t in
            t.paneStates[paneID] = paneState
            t.scrollbackPaths[paneID] = scrollback
            t.initialCommands[paneID] = initial
            t.initialPromptFiles[paneID] = "/tmp/limpid-prompts/merge"
            t.initialAgentExecutables[paneID] = AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex")
            t.agentSessions[.claude, default: [:]][paneID] = claudeSession
            t.agentSessions[.codex, default: [:]][paneID] = codexSession
            t.agentBadges[.claude, default: [:]][paneID] = claudeBadge
            t.agentBadges[.codex, default: [:]][paneID] = codexBadge
            t.tmuxBindings[paneID] = tmuxBinding
        }
        #expect(updated, "Setting per-pane state should mutate the tab")

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        let sourceAfter = session.tab(source.id)
        let targetAfter = try #require(session.tab(target.id))
        // Migrated values present on target — each field checked
        // explicitly so a cross-field bug at the action site shows up
        // as a precise diff rather than a vague "something is wrong".
        #expect(targetAfter.paneStates[paneID] == paneState)
        #expect(session.paneState(paneID).name == "tests")
        #expect(targetAfter.scrollbackPaths[paneID] == scrollback)
        #expect(targetAfter.initialCommands[paneID] == initial)
        #expect(targetAfter.initialPromptFiles[paneID] == "/tmp/limpid-prompts/merge")
        #expect(targetAfter.initialAgentExecutables[paneID] == AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex"))
        #expect(targetAfter.agentSessions[.claude, default: [:]][paneID] == claudeSession)
        #expect(targetAfter.agentSessions[.codex, default: [:]][paneID] == codexSession)
        #expect(targetAfter.agentBadges[.claude, default: [:]][paneID] == claudeBadge)
        #expect(targetAfter.agentBadges[.codex, default: [:]][paneID] == codexBadge)
        #expect(targetAfter.tmuxBindings[paneID] == tmuxBinding)
        // And the source tab, which keeps the sibling, holds none of it any
        // more.
        #expect(sourceAfter?.paneStates[paneID] == nil)
        #expect(sourceAfter?.scrollbackPaths[paneID] == nil)
        #expect(sourceAfter?.initialCommands[paneID] == nil)
        #expect(sourceAfter?.initialPromptFiles[paneID] == nil)
        #expect(sourceAfter?.initialAgentExecutables[paneID] == nil)
        #expect(sourceAfter?.agentSessions[.claude, default: [:]][paneID] == nil)
        #expect(sourceAfter?.agentSessions[.codex, default: [:]][paneID] == nil)
        #expect(sourceAfter?.agentBadges[.claude, default: [:]][paneID] == nil)
        #expect(sourceAfter?.agentBadges[.codex, default: [:]][paneID] == nil)
        #expect(sourceAfter?.tmuxBindings[paneID] == nil)
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

    // MARK: - Conversation names

    private static func conversation(_ name: String, paneID: UUID, startedAt seconds: TimeInterval) -> ConversationName {
        ConversationName(
            name: name,
            provider: .claude,
            paneID: paneID,
            conversationID: name,
            startedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("the moved pane's conversation name goes with it, and the earlier name stays in the target")
    func movedPane_takesItsConversationName() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget()
        let moved = Self.conversation("Moved task", paneID: paneID, startedAt: 10)
        _ = session.update(source.id) { $0.conversationName = moved }

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        #expect(session.tab(source.id)?.conversationName == nil)
        #expect(session.tab(target.id)?.conversationName == moved)

        // Then into a tab whose own conversation started first: that one
        // keeps naming it.
        let other = session.openTab(container: .loose)
        let otherPane = try #require(other.splitTree.allLeafIDs().first)
        let earlier = Self.conversation("Earlier task", paneID: otherPane, startedAt: 5)
        _ = session.update(other.id) { $0.conversationName = earlier }
        TabActions.mergePaneIntoTab(session, paneID: paneID, into: other.id)
        // The tab the pane left (`target`) holds no name, `other` keeps its
        // own, and the later name the pane brought is dropped, not kept
        // anywhere.
        #expect(session.tab(target.id)?.conversationName == nil)
        #expect(session.tab(other.id)?.conversationName == earlier)
        #expect(!session.tabs.contains { $0.conversationName == moved })
    }

    @Test("a pane whose tab is named by another pane leaves the name where it is")
    func movedPane_leavesAnotherPanesName() throws {
        let (session, source, target, paneID) = try Self.sessionWithSourceAndTarget()
        let sibling = try #require(source.splitTree.allLeafIDs().first { $0 != paneID })
        let name = Self.conversation("Sibling task", paneID: sibling, startedAt: 10)
        _ = session.update(source.id) { $0.conversationName = name }

        TabActions.mergePaneIntoTab(session, paneID: paneID, into: target.id)

        #expect(session.tab(source.id)?.conversationName == name)
        #expect(session.tab(target.id)?.conversationName == nil)
    }

    @Test("a pane moved to a new tab takes its conversation name there")
    func movedToNewTab_takesItsConversationName() throws {
        let (session, source, _, paneID) = try Self.sessionWithSourceAndTarget()
        let moved = Self.conversation("Moved task", paneID: paneID, startedAt: 10)
        _ = session.update(source.id) { $0.conversationName = moved }

        TabActions.movePaneToNewTab(session, paneID: paneID, in: session.primaryWindowID, intent: .person)

        #expect(session.tab(source.id)?.conversationName == nil)
        #expect(session.tab(containing: paneID)?.conversationName == moved)
    }

    /// The source tab of `sessionWithSourceAndTarget`, split in two.
    private static func sourceAndPane() throws -> (session: WorkspaceSession, source: Tab) {
        let (session, source, _, _) = try sessionWithSourceAndTarget()
        return (session, source)
    }

    // MARK: - A tab of its own

    @Test func movePaneToNewTab_namedPane_namesNewTab() throws {
        let (session, source) = try Self.sourceAndPane()
        let paneID = try #require(source.splitTree.allLeafIDs().last)
        session.renamePane(paneID, to: "server")

        TabActions.movePaneToNewTab(session, paneID: paneID)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.id != source.id)
        #expect(moved.displayTitle == "server")
        #expect(moved.titleOverride == "server")
        #expect(moved.paneStates[paneID]?.name == "server")
        #expect(session.tab(source.id)?.paneStates[paneID] == nil)
    }

    /// A pane moved before its terminal is made keeps its staged launch,
    /// the executable the new workspace sheet found with it.
    @Test func movePaneToNewTab_carriesTheStagedExecutable() throws {
        let (session, source) = try Self.sourceAndPane()
        let paneID = try #require(source.splitTree.allLeafIDs().last)
        let found = AgentInstallation(kind: .codex, executable: "/opt/tools/bin/codex")
        session.update(source.id) { $0.initialCommands[paneID] = "codex" }
        session.stageAgentExecutable(found, paneID: paneID)

        TabActions.movePaneToNewTab(session, paneID: paneID)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.id != source.id)
        #expect(moved.initialAgentExecutables[paneID] == found)
        #expect(session.stagedLaunch(paneID: paneID)?.agentExecutable == found)
        #expect(session.tab(source.id)?.initialAgentExecutables[paneID] == nil)
    }

    @Test func movePaneToNewTab_unnamedPane_keepsSourceTitle() throws {
        let (session, source) = try Self.sourceAndPane()
        session.update(source.id) { $0.title = "source title" }
        let paneID = try #require(source.splitTree.allLeafIDs().last)

        TabActions.movePaneToNewTab(session, paneID: paneID)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.title == "source title")
        #expect(moved.titleOverride == nil)
    }

    /// A pane in a tab no window shows, moved in the window named (the one
    /// its views pass), gets a tab of its own there.
    @Test func movePaneToNewTab_ofAPaneNoWindowShows_movesItInTheWindowNamed() throws {
        let (session, source) = try Self.sourceAndPane()
        let paneID = try #require(source.splitTree.allLeafIDs().last)
        session.openTab(container: .loose)
        #expect(session.window(showingPane: paneID) == nil)

        TabActions.movePaneToNewTab(session, paneID: paneID, in: session.primaryWindowID, intent: .person)

        let moved = try #require(session.tab(containing: paneID))
        #expect(moved.id != source.id)
        #expect(session.primarySelection.activeTabID == moved.id)
    }

    @Test func theAgentInFront_travelsWithItsPane() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "beta")
        let container = ContainerID.project(project.id)
        let pane = try #require(TabActions.newTab(session, in: container, running: .codex))
        PaneActions.split(session, direction: .horizontal)
        let source = try #require(session.tab(containing: pane))

        TabActions.movePaneToNewTab(session, paneID: pane)

        let moved = try #require(session.tab(containing: pane))
        #expect(moved.id != source.id)
        #expect(moved.agentKind == .codex)
        #expect(session.tab(source.id)?.agentsInFront[pane] == nil)
    }

    @Test func paneTransferState_roundTripsAndClears_keepingWhatThePaneLacked() {
        let pane = UUID()
        var source = Tab(title: "source", splitTree: SplitTree(leafID: pane), container: .loose)
        source.paneStates[pane] = PaneState(unreadCount: 2, name: "moved")
        source.agentSessions[.claude, default: [:]][pane] = AgentSessionInfo(sessionId: "c1", cwd: "/tmp/c")
        source.initialCommands[pane] = "make test"
        // The target already holds a scrollback path for the pane id, which
        // the moved pane has none of: applying keeps it, as the merge did.
        var target = Tab(title: "target", splitTree: SplitTree(leafID: UUID()), container: .loose)
        target.scrollbackPaths[pane] = "/tmp/kept.vt"

        let state = source.paneTransferState(of: pane)
        target.apply(state, to: pane)
        source.removePaneTransferState(of: pane)

        #expect(target.paneTransferState(of: pane) == Tab.PaneTransferState(
            paneState: PaneState(unreadCount: 2, name: "moved"),
            agentSessions: [.claude: AgentSessionInfo(sessionId: "c1", cwd: "/tmp/c")],
            scrollbackPath: "/tmp/kept.vt",
            initialCommand: "make test"
        ))
        #expect(source.paneTransferState(of: pane) == Tab.PaneTransferState())
    }
}
