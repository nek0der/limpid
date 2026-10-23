// WorktreeMoveSuggesterTests.swift
// Limpid — covers the case A matcher and the path normalizer that
// drive the worktree-move banner. The async case B path is exercised
// through `GitWorktreeListTests` against a real tmp repo, so this
// suite keeps to the pure-data shapes that make up most of the
// suggester's surface.

import Foundation
import Testing
@testable import Limpid

@Suite("WorktreeMoveSuggester")
@MainActor
struct WorktreeMoveSuggesterTests {

    // MARK: - RepositoryPath.contains

    @Test(arguments: [
        ("/a/b", "/a/b", true),
        ("/a/b/", "/a/b", true),
        ("/a/b", "/a/b/", true),
        ("/a/b", "/a/b/c", true),
        ("/a/b", "/a/bc", false),
        ("/a/b/c", "/a/b", false),
        ("/", "/a", true)
    ])
    func contains_readsAFolderAndWhatIsInIt(parent: String, child: String, isInside: Bool) {
        #expect(RepositoryPath.contains(parent, child) == isInside)
    }

    /// The root `/` holds every other path, as any folder holds what is in
    /// it; a `"/" + "/"` prefix test would hold none.
    @Test(arguments: [
        ("/a/b", "/a/b/c", true),
        ("/a/b/", "/a/b/c", true),
        ("/a/b", "/a/b", false),
        ("/a/b", "/a/b/", false),
        ("/a/b", "/a/bc", false),
        ("/", "/a", true),
        ("/", "/", false)
    ])
    func isStrictDescendant_readsWhatIsInAFolder_notTheFolder(parent: String, child: String, isInside: Bool) {
        #expect(RepositoryPath.isStrictDescendant(child, of: parent) == isInside)
    }

    // MARK: - matchRegisteredWorktree

    /// A registered worktree of `/repo`, by its label.
    struct RegisteredWorktree: Sendable {
        let label: String
        let path: String
        var isHidden = false
    }

    /// What the matcher should answer, with the matched worktree by label.
    enum ExpectedMatch: Equatable, Sendable {
        case none
        case alreadyInside
        case reparent(to: String)
    }

    /// A cd into `newCwd` by a tab in the project's own folder, or in the
    /// worktree labeled `source`.
    struct MatchCase: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let worktrees: [RegisteredWorktree]
        let source: String?
        let newCwd: String
        let expected: ExpectedMatch

        init(
            _ description: String,
            _ worktrees: [RegisteredWorktree],
            source: String? = nil,
            cd newCwd: String,
            _ expected: ExpectedMatch
        ) {
            testDescription = description
            self.worktrees = worktrees
            self.source = source
            self.newCwd = newCwd
            self.expected = expected
        }
    }

    private nonisolated static let feat = RegisteredWorktree(label: "feat", path: "/repo-feat")
    private nonisolated static let nested = [
        RegisteredWorktree(label: "outer", path: "/repo/worktrees"),
        RegisteredWorktree(label: "inner", path: "/repo/worktrees/feature")
    ]
    private nonisolated static let hidden = RegisteredWorktree(label: "old", path: "/repo-old", isHidden: true)

    @Test(arguments: [
        MatchCase("outside every worktree", [feat], cd: "/some/other/path", .none),
        // `.alreadyInside`, not `.none`: it is what stops `handleEvent`
        // before the shell-out to git, which would add the worktree again.
        MatchCase("inside the source tab's own worktree", [feat], source: "feat", cd: "/repo-feat/src", .alreadyInside),
        MatchCase("at the source tab's own worktree", [feat], source: "feat", cd: "/repo-feat", .alreadyInside),
        MatchCase("a worktree, from the project's folder", [feat], cd: "/repo-feat", .reparent(to: "feat")),
        MatchCase("a worktree nested in another: the longest wins", nested, cd: "/repo/worktrees/feature/src", .reparent(to: "inner")),
        MatchCase(
            "a worktree nested in the source tab's: the nested one wins",
            nested,
            source: "outer",
            cd: "/repo/worktrees/feature/src",
            .reparent(to: "inner")
        ),
        MatchCase("a hidden worktree is not matched", [hidden], cd: "/repo-old/src", .none),
        // `/repo-feat-extra` shares the text `/repo-feat` without being in it.
        MatchCase("a sibling that shares a prefix", [feat], cd: "/repo-feat-extra", .none)
    ])
    func match_answersForTheWorktreeTheCdLandsIn(_ match: MatchCase) throws {
        let worktrees = match.worktrees.map {
            WorktreeFixture.make(label: $0.label, workingDirectory: URL(fileURLWithPath: $0.path), isHidden: $0.isHidden)
        }
        let project = Project(name: "repo", rootURL: URL(fileURLWithPath: "/repo"), worktrees: worktrees)
        let container: ContainerID = try match.source.map { label in
            try .worktree(projectID: project.id, worktreeID: #require(worktrees.first { $0.label == label }).id)
        } ?? .project(project.id)
        let sourceTab = Tab(title: "source", splitTree: SplitTree(leafID: UUID()), container: container)

        let result = WorktreeMoveSuggester.matchRegisteredWorktree(newCwd: match.newCwd, sourceTab: sourceTab, sourceProject: project)

        let expected: WorktreeMoveSuggester.RegisteredMatch = switch match.expected {
        case .none: .noRegisteredWorktreeContains
        case .alreadyInside: .alreadyInsideSourceWorktree
        case let .reparent(label): try .reparentTo(.reparentToRegistered(
                projectID: project.id,
                worktreeID: #require(worktrees.first { $0.label == label }).id,
                label: label
            ))
        }
        #expect(result == expected)
    }

    // MARK: - Windows

    /// A project with one registered worktree, its tab shown only in a
    /// second window while the primary is on the scratch tabs.
    private struct TwoWindows {
        let session: WorkspaceSession
        let other: WindowID
        let tab: Tab
        let pane: UUID
        let worktree: Worktree
    }

    private func twoWindows() throws -> TwoWindows {
        // The primary shows a project of its own, so the second window can
        // show this one.
        let (session, home) = WorkspaceSessionFixture.withProject(rootURL: URL(fileURLWithPath: "/repo-home"))
        session.openTab(container: .project(home.id))
        let project = session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/repo-windows"))
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "feat",
            workingDirectory: URL(fileURLWithPath: "/repo-windows-feat"),
            branchName: "feat"
        ))
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let tab = session.openTab(container: .project(project.id), in: other)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        session.openTab(container: .loose)
        return TwoWindows(session: session, other: other, tab: tab, pane: pane, worktree: worktree)
    }

    @Test("a suggestion shows while any window shows its tab, and only that window moves on OK")
    func suggestion_followsTheWindowShowingItsTab() throws {
        let fixture = try twoWindows()
        let (session, other, tab, pane, worktree) = (fixture.session, fixture.other, fixture.tab, fixture.pane, fixture.worktree)
        let suggester = WorktreeMoveSuggester()
        suggester.bind(session: session)
        let primaryTab = session.primarySelection.activeTabID

        suggester.handleEvent(paneID: pane, newCwd: "/repo-windows-feat/src", oldCwd: nil)
        #expect(suggester.current?.paneID == pane)

        suggester.accept()
        let moved = try ContainerID.worktree(projectID: #require(tab.container.projectID), worktreeID: worktree.id)
        #expect(session.tab(tab.id)?.container == moved)
        #expect(session.selection(other)?.activeContainerID == moved)
        #expect(session.selection(other)?.activeTabID == tab.id)
        #expect(session.primarySelection.activeTabID == primaryTab)
    }

    @Test("a view that holds the tab follows it into the worktree of its own project")
    func acceptingAMoveWithinTheProject_movesAViewThatHoldsTheTab() throws {
        let fixture = try twoWindows()
        let (session, other, tab, pane, worktree) = (fixture.session, fixture.other, fixture.tab, fixture.pane, fixture.worktree)
        let projectID = try #require(tab.container.projectID)
        let suggester = WorktreeMoveSuggester()
        suggester.bind(session: session)
        suggester.handleEvent(paneID: pane, newCwd: "/repo-windows-feat/src", oldCwd: nil)
        let suggestion = try #require(suggester.current)
        // The window leaves the project, which keeps a view on the tab.
        session.showProject(nil, in: other, intent: .person, reason: .person)
        #expect(session.projectViews[projectID]?.activeTabID == tab.id)

        suggester.current = suggestion
        suggester.accept()

        let moved = ContainerID.worktree(projectID: projectID, worktreeID: worktree.id)
        #expect(session.projectViews[projectID]?.activeContainerID == moved)
        #expect(session.projectViews[projectID]?.activeTabID == tab.id)
    }

    @Test("a worktree of another project takes the tab there, and the window that drew it switches to that project")
    func acceptingAMoveToAnotherProjectsWorktree_switchesTheWindowThatDrewTheTab() throws {
        let fixture = try twoWindows()
        let (session, other, tab, pane) = (fixture.session, fixture.other, fixture.tab, fixture.pane)
        let source = try #require(tab.container.projectID)
        let elsewhere = session.addOrActivateProject(rootURL: URL(fileURLWithPath: "/repo-elsewhere"), suggestedName: "elsewhere")
        let worktree = try #require(session.attachGitWorktree(
            projectID: elsewhere.id,
            label: "x",
            workingDirectory: URL(fileURLWithPath: "/repo-elsewhere-x"),
            branchName: "x"
        ))
        let sibling = session.openTab(container: .project(source), in: other)
        session.setActiveTab(tab.id, in: other)
        let switches = ProjectSwitchRecorder.connect(to: session)
        let suggester = WorktreeMoveSuggester()
        suggester.bind(session: session)
        suggester.current = WorktreeMoveSuggestion(
            paneID: pane,
            newCwd: URL(fileURLWithPath: "/repo-elsewhere-x"),
            kind: .reparentToRegistered(projectID: elsewhere.id, worktreeID: worktree.id, label: "x")
        )

        suggester.accept()

        // The window the person said OK in now shows the other project, on
        // the tab; no window was made for it.
        #expect(session.selection(other)?.shownProjectID == elsewhere.id)
        #expect(session.selection(other)?.activeTabID == tab.id)
        #expect(session.tab(tab.id)?.container == .worktree(projectID: elsewhere.id, worktreeID: worktree.id))
        #expect(session.windowIDs.count == 2)
        #expect(switches.raised.isEmpty)
        #expect(switches.switches.map(\.window) == [other])
        // The project it left keeps the session the tab left from.
        #expect(session.projectViews[source]?.activeTabID == sibling.id)
    }

    @Test("a suggestion is put away once no window shows its tab, and comes back with it")
    func suggestion_parksWhenNoWindowShowsItsTab() throws {
        let fixture = try twoWindows()
        let (session, other, tab, pane) = (fixture.session, fixture.other, fixture.tab, fixture.pane)
        let suggester = WorktreeMoveSuggester()
        suggester.bind(session: session)
        suggester.handleEvent(paneID: pane, newCwd: "/repo-windows-feat", oldCwd: nil)
        #expect(suggester.current != nil)

        session.setActiveContainer(.loose, in: other)
        suggester.shownTabsDidChange()
        #expect(suggester.current == nil)

        session.setActiveTab(tab.id, in: other)
        suggester.shownTabsDidChange()
        #expect(suggester.current?.paneID == pane)
    }
}
