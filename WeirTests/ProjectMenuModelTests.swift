// ProjectMenuModelTests.swift
// Weir — the title bar's project dropdown.

import CoreGraphics
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

struct ProjectMenuModelTests {
    private static func project(_ name: String, path: String? = nil) -> Project {
        Project(name: name, rootURL: URL(fileURLWithPath: path ?? "/tmp/\(name)"), paletteIndex: 0)
    }

    private static func facts(
        attention: [UUID: AttentionCounts] = [:],
        running: [UUID: Int] = [:],
        shown: Set<UUID> = []
    ) -> ProjectMenuModel.Facts {
        ProjectMenuModel.Facts(
            attention: { attention[$0] ?? AttentionCounts() },
            running: { running[$0] ?? 0 },
            isShown: { shown.contains($0) }
        )
    }

    /// The rows keep the order they are given, the sidebar's: nothing
    /// moves up for being used.
    @Test func projects_comeInTheOrderGiven() {
        let projects = ["c", "a", "d", "b"].map { Self.project($0) }

        let model = ProjectMenuModel(projects: projects, currentProjectID: nil, query: "", facts: Self.facts())

        #expect(model.rows.map(\.name) == ["c", "a", "d", "b"])
    }

    /// The dropdown lists the projects in the window's sidebar order, the
    /// ones its order has not met last, in the session's order.
    @MainActor
    @Test func theDropdown_listsTheProjectsInTheWindowsSidebarOrder() {
        let fixture = ProjectWindowsFixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id, fixture.a.id])

        let rows = ProjectMenuModel(
            session: fixture.session,
            registry: fixture.registry,
            window: fixture.primary.selection,
            query: "",
            attentionQueue: AttentionQueue(),
            attention: AttentionState()
        ).rows

        #expect(rows.map(\.id) == [fixture.c.id, fixture.a.id, fixture.b.id])
        #expect(rows.map(\.isCurrent) == [false, true, false])
    }

    @Test func theSearch_matchesTheNameOrTheFolder_withoutCase() {
        let projects = [Self.project("Weir"), Self.project("notes", path: "/Users/me/work/weir-notes"), Self.project("other")]

        let model = ProjectMenuModel(projects: projects, currentProjectID: nil, query: " WEIR ", facts: Self.facts())

        #expect(model.rows.map(\.name) == ["Weir", "notes"])
        #expect(ProjectMenuModel(projects: projects, currentProjectID: nil, query: "zzz", facts: Self.facts()).rows.isEmpty)
    }

    @Test func eachRow_carriesItsCounts_andMarksTheWindowsProject() {
        let projects = [Self.project("a"), Self.project("b")]
        let facts = Self.facts(
            attention: [projects[0].id: AttentionCounts(stops: 1), projects[1].id: AttentionCounts(unread: 2)],
            running: [projects[1].id: 3]
        )

        let rows = ProjectMenuModel(projects: projects, currentProjectID: projects[1].id, query: "", facts: facts).rows

        #expect(rows.map(\.attention.style) == [.blocking, .unreadOnly])
        #expect(rows.map(\.running) == [0, 3])
        #expect(rows.map(\.isCurrent) == [false, true])
    }

    @Test func aProjectAnotherWindowShows_isMarked_butNotTheWindowsOwn() {
        let projects = [Self.project("a"), Self.project("b"), Self.project("c")]
        // `b` is this window's; `a` is shown in another; `c` in none.
        let facts = Self.facts(shown: [projects[0].id, projects[1].id])

        let rows = ProjectMenuModel(projects: projects, currentProjectID: projects[1].id, query: "", facts: facts).rows

        #expect(rows.map(\.isInOtherWindow) == [true, false, false])
    }

    @Test func theMenu_countsTowardThePalettesOrder() {
        let id = UUID()
        #expect(ProjectMenuModel.frecencyKey(id) == CommandPaletteAction.activateProject(id).frecencyKey)
    }

    @Test(arguments: [
        ("weir", "WE"),
        ("weir-site", "WS"),
        ("my-side-project", "MS"),
        ("-dotfiles", "DO"),
        ("a", "A"),
        ("", ""),
    ])
    func theMark_takesTwoWordsInitials_elseTheFirstTwoLetters(name: String, initials: String) {
        #expect(ProjectMenuModel.initials(of: name) == initials)
    }

    @Test func theControlsTooltip_countsOtherProjectsItems_onlyWhenThereAreAny() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 0, locale: english) == "Project")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 3, locale: english) == "Project · Other projects need attention: 3")
        #expect(ProjectMenuModel.controlHelp(otherProjectsCount: 3, locale: japanese) == "プロジェクト · ほかのプロジェクトに要対応 3 件")
    }

    @Test func theRowsTooltip_namesTheCurrentWindow_orHowToOpenANewOne() {
        func row(isCurrent: Bool, isInOtherWindow: Bool = false) -> ProjectMenuModel.Row {
            ProjectMenuModel.Row(
                id: UUID(),
                name: "weir-site",
                paletteIndex: nil,
                isCurrent: isCurrent,
                isInOtherWindow: isInOtherWindow,
                attention: NeedsAttentionPillModel(AttentionCounts()),
                running: 0
            )
        }
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: true), locale: english) == "Current Window")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: true), locale: japanese) == "現在のウインドウ")
        // Choosing another switches this window, and ⌘-click opens it in a
        // new one; one another window shows says so on the row
        // itself, as that window comes forward either way.
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false), locale: english) == "⌘-click to open in a new window")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false), locale: japanese) == "⌘ クリックで新しいウインドウに開く")
        #expect(ProjectMenuModel.rowHelp(row(isCurrent: false, isInOtherWindow: true), locale: english) == nil)
        // What the tooltip and the VoiceOver action both read.
        #expect(row(isCurrent: false).opensInNewWindow)
        #expect(!row(isCurrent: true).opensInNewWindow)
        #expect(!row(isCurrent: false, isInOtherWindow: true).opensInNewWindow)
    }

    /// The window's project ends with Close Project…, after its settings
    /// and its folder.
    @Test func theWindowsProject_offersCloseProject_afterItsSettingsAndFolder() {
        let projects = [Self.project("a"), Self.project("b")]

        #expect(
            ProjectMenuModel.projectItems(for: projects[1].id, in: projects)
                == [.settings, .revealInFinder, .close]
        )
    }

    /// A window that shows no project, or one just removed, has nothing to
    /// close.
    @Test func noProject_orOneGone_offersNothingToClose() {
        let projects = [Self.project("a")]

        #expect(ProjectMenuModel.projectItems(for: nil, in: projects).isEmpty)
        #expect(ProjectMenuModel.projectItems(for: UUID(), in: projects).isEmpty)
    }

    /// Choosing Close Project… raises the confirmation for that project,
    /// named; a project already gone raises none.
    @MainActor
    @Test func closeProject_raisesTheConfirmationForThatProject() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")

        let target = TitleBarMenuHost.closeTarget(for: project.id, in: session)

        #expect(target?.projectID == project.id)
        #expect(target?.name == "weir")
        #expect(TitleBarMenuHost.closeTarget(for: UUID(), in: session) == nil)
        #expect(TitleBarMenuHost.closeTarget(for: nil, in: session) == nil)
    }

    /// The confirmation says the agents stop only when one runs in the
    /// project's own tabs: one in a scratch tab is not the project's.
    @MainActor
    @Test func closeProject_saysAgentsStop_onlyForTheProjectsOwn() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let scratch = session.openTab(container: .loose)
        func run(in tab: Tab) {
            let pane = tab.splitTree.allLeafIDs()[0]
            session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .running, updatedAt: Date())] }
        }

        #expect(!session.hasLiveAgent(inProject: project.id))
        run(in: scratch)
        #expect(!session.hasLiveAgent(inProject: project.id))
        run(in: tab)
        #expect(session.hasLiveAgent(inProject: project.id))
    }
}
