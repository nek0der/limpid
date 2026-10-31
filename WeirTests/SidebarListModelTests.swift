// SidebarListModelTests.swift
// Weir — every project under its own header in the sidebar: the order, the folds, the counts, and the marks of a folded header.

import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@MainActor
struct SidebarListModelTests {
    typealias Fixture = ProjectWindowsFixture

    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// The sidebar of `window`, read from `queue`, with `running` agents in
    /// each project.
    private static func model(
        _ fixture: Fixture,
        window: ProjectWindowState? = nil,
        queue: AttentionQueue = AttentionQueue(),
        running: [UUID: Int] = [:],
        openedByDrag: Set<UUID> = []
    ) -> SidebarListModel {
        let window = window ?? fixture.primary
        let showing = { (id: UUID) -> WindowID? in
            let other = fixture.registry.window(showingProject: id, in: fixture.session)
            return other?.id == window.id ? nil : other?.id
        }
        let sections = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: window.id,
            windowShowing: showing,
            queue: queue,
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        return SidebarListModel(
            session: fixture.session,
            window: window.id,
            sections: sections,
            windowShowing: showing,
            sources: SidebarListModel.Sources(
                queue: queue,
                runtimes: [],
                approvals: ApprovalLedger(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil },
                running: { running[$0] ?? 0 },
                locale: english
            ),
            openedByDrag: openedByDrag
        )
    }

    /// An item of `kind` in a pane of `project`, as the attention list holds
    /// one.
    private static func item(_ kind: AttentionItemKind, in project: Project, _ queue: inout AttentionQueue) {
        let run = UUID().uuidString
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(run), episodeToken: "1")),
            kind: kind,
            subject: .runtime(id: run, provider: .claude, paneID: UUID(), tabID: nil, projectID: project.id),
            arrivedAt: Date()
        )
    }

    // MARK: - Empty

    /// With no project the list has no header, and says so with the way to
    /// add one, rather than leave a blank over the scratch row; with a
    /// project it lists it and says nothing.
    @Test func noProject_saysThereIsNone_andAProjectListsIt() {
        let fixture = Fixture()

        #expect(SidebarListModel(groups: [], scratchRow: .test(.test(container: .loose))).emptyState == .noProjects)
        #expect(Self.model(fixture).emptyState == nil)
    }

    // MARK: - Order and folds

    /// Every project has a header, in the window's order, new ones at the
    /// bottom; the window's project is open, a project with one working row
    /// folded by default.
    @Test func everyProject_isListedUnderItsHeader_inTheWindowsOrder() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.c.id])

        let model = Self.model(fixture)

        #expect(model.headers.map(\.id) == [fixture.c.id, fixture.a.id, fixture.b.id])
        #expect(model.headers.map(\.isCurrent) == [false, true, false])
        #expect(model.headers.map(\.isCollapsed) == [false, false, true], "c is met and open; b has one row")
        #expect(model.items.map(\.id) == [
            .header(fixture.c.id), .row(.project(fixture.c.id)),
            .header(fixture.a.id), .row(.project(fixture.a.id)),
            .header(fixture.b.id)
        ])
        #expect(model.rows(ofProject: fixture.b.id).isEmpty, "a folded header builds no row")
        #expect(Set(model.items.map(\.id)).count == model.items.count, "no two lines share an id")
    }

    /// A header the person folded stays folded, the window's own included,
    /// and its rows are counted rather than built.
    @Test func aFoldedHeader_countsItsRows_andBuildsNone() {
        let fixture = Fixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(
            projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id],
            collapsedProjects: [fixture.a.id]
        )

        let model = Self.model(fixture)
        let header = model.headers[0]

        #expect(header.isCollapsed)
        #expect(header.workingCount == 1)
        #expect(model.rows.map(\.id) == [.project(fixture.b.id), .project(fixture.c.id)])
    }

    /// A folded project a dragged tab rested on is drawn open for the drag
    /// alone: its rows are built, and the window's arrangement still has it
    /// folded, so a drag that goes elsewhere leaves it as it was.
    @Test func aFoldedProjectOpenedByDrag_isDrawnOpen_andStaysFoldedInTheArrangement() {
        let fixture = Fixture()
        let arrangement = SidebarArrangement(
            projectOrder: [fixture.a.id, fixture.b.id, fixture.c.id],
            collapsedProjects: [fixture.b.id]
        )
        fixture.primary.selection.sidebarArrangement = arrangement

        let model = Self.model(fixture, openedByDrag: [fixture.b.id])

        #expect(model.headers.first { $0.id == fixture.b.id }?.isCollapsed == false)
        #expect(model.rows(ofProject: fixture.b.id).map(\.id) == [.project(fixture.b.id)])
        #expect(fixture.primary.selection.sidebarArrangement == arrangement)
        #expect(Self.model(fixture).headers.first { $0.id == fixture.b.id }?.isCollapsed == true)
    }

    @Test func theDefaultFold_opensTheWindowsProject_andOneWithRows_butNotAnotherWindows() {
        #expect(SidebarFoldDefault.isOpen(isCurrent: true, isInOtherWindow: false, workingCount: 0))
        #expect(SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: false, workingCount: 2))
        #expect(!SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: false, workingCount: 1))
        #expect(!SidebarFoldDefault.isOpen(isCurrent: false, isInOtherWindow: true, workingCount: 5))
    }

    /// The scratch row is the window's while it is on it, and never part of
    /// a project's list.
    @Test func theScratchRow_isActiveOnlyWhileTheWindowIsOnIt() {
        let fixture = Fixture()
        #expect(!Self.model(fixture).isScratchActive)
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        let model = Self.model(fixture)
        #expect(model.isScratchActive)
        #expect(!model.items.contains { $0.id == .row(.loose) })
    }

    /// With only shells in it, the row wears a shell's mark and no badge, as
    /// a worktree's row of shells does, and is not called a project's folder.
    @Test func theScratchRow_ofShells_wearsTheShellMarkAlone() {
        let fixture = Fixture()
        _ = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let row = Self.model(fixture).scratchRow
        #expect(row.fact.glyph == .shell)
        #expect(row.agentKinds.isEmpty)
        #expect(!row.isMainFolder)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(SessionRowFactText.scratchTooltip(for: row, startFolder: home, now: .now, locale: Self.english) == "~")
        #expect(SessionRowFactText.scratchHint(startFolder: home, locale: Self.english) == "Its tabs start in the home folder")
    }

    /// A scratch tab's agent shows on the row while another row is open, so
    /// the wait is not found only by opening the scratch tabs.
    @Test func theScratchRow_showsItsAgentsWait() throws {
        let fixture = Fixture()
        let tab = fixture.session.openTab(container: .loose, in: fixture.primary.id, intent: .person, selects: false)
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        let run = UUID().uuidString
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(run), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: nil)),
            subject: .runtime(id: run, provider: .claude, paneID: pane, tabID: tab.id, projectID: nil),
            arrivedAt: Date()
        )
        let row = Self.model(fixture, queue: queue).scratchRow
        #expect(row.fact.glyph == .needsResponse)
        #expect(row.agentKinds == [.claude])
        #expect(!row.isActive)
        let folder = URL(fileURLWithPath: "/tmp/weir-scratch")
        #expect(SessionRowFactText.scratchTooltip(for: row, startFolder: folder, now: .now, locale: Self.english)
            == "/tmp/weir-scratch · Needs response\nOpen the pane to answer in the terminal")
        #expect(SessionRowFactText.scratchHint(startFolder: folder, locale: Self.japanese) == "タブはweir-scratchで開始します")
    }

    /// A window choosing a project shows nothing, so the scratch row it was
    /// on stands there unmarked.
    @Test func theScratchRow_isNotActiveWhileTheWindowChoosesAProject() {
        let fixture = Fixture()
        fixture.session.setActiveContainer(.loose, in: fixture.primary.id, intent: .person)
        fixture.session.primarySelection.isChoosingProject = true
        #expect(!Self.model(fixture).scratchRow.isActive)
    }

    // MARK: - Another window's project

    /// A project another window shows says so in its header and is folded
    /// by default.
    @Test func aProjectAnotherWindowShows_isMarked_andFoldedByDefault() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)

        let model = Self.model(fixture)
        let header = try #require(model.headers.first { $0.id == fixture.b.id })
        #expect(header.isInOtherWindow)
        #expect(header.isCollapsed)
        #expect(model.headers.filter(\.isInOtherWindow).map(\.id) == [fixture.b.id])
        // The other window lists the primary's project as another window's.
        let fromOther = Self.model(fixture, window: other)
        #expect(fromOther.headers.filter(\.isInOtherWindow).map(\.id) == [fixture.a.id])
        #expect(fromOther.headers.first { $0.id == fixture.b.id }?.isCurrent == true)
    }

    // MARK: - A folded header's marks

    /// A folded header shows one mark of each kind inside it, a wait first,
    /// then a stop, then a turn running; an unread turn none.
    @Test func aFoldedHeader_showsAWaitAStopAndARun_inThatOrder_butNoUnread() {
        let fixture = Fixture()
        var queue = AttentionQueue()
        Self.item(.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown)), in: fixture.b, &queue)
        Self.item(.stop(.processExited), in: fixture.b, &queue)
        Self.item(.approval(ApprovalFact.test()), in: fixture.b, &queue)
        Self.item(.approval(ApprovalFact.test()), in: fixture.b, &queue)
        Self.item(.stop(.processExited), in: fixture.a, &queue)

        let model = Self.model(fixture, queue: queue, running: [fixture.b.id: 2, fixture.a.id: 1])
        let folded = model.headers.first { $0.id == fixture.b.id }
        let open = model.headers.first { $0.id == fixture.a.id }

        #expect(folded?.marks == [.needsApproval, .stopped, .running])
        #expect(folded?.requestKeys.count == 2, "its card stands beside the header")
        #expect(open?.marks == [], "an open header's rows show their own")
        #expect(open?.requestKeys == [])
    }

    @Test(arguments: [
        (AttentionCounts(questions: 1), 0, [SessionRowFact.Glyph.needsAnswer]),
        (AttentionCounts(prompts: 1), 0, [.needsResponse]),
        (AttentionCounts(signIns: 1), 0, [.needsSignIn]),
        (AttentionCounts(approvals: 1, questions: 1), 0, [.needsApproval]),
        (AttentionCounts(unread: 3), 0, []),
        (AttentionCounts(), 1, [.running]),
        (AttentionCounts(), 0, [])
    ])
    func theMarks_ofWhatIsInside(_ counts: AttentionCounts, running: Int, expected: [SessionRowFact.Glyph]) {
        #expect(SidebarProjectHeader.marks(counts: counts, running: running) == expected)
    }

    // MARK: - The hold, across projects

    /// While the pointer is on the sidebar, a row of a project the window
    /// does not show keeps its section too: every project's rows are in
    /// sight.
    @Test func theHold_keepsTheSectionsOfEveryProjectsRows() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .discovered)
        let row = ContainerID.worktree(projectID: fixture.b.id, worktreeID: worktree.id)
        window.present(SidebarPresentedSections(sections: [row: .working]))
        window.isPointerInSidebar = true

        let computed = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: window.id,
            windowShowing: { _ in nil },
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        #expect(computed.section(of: row) == .other)
        #expect(window.presentedSections(computed: computed, isDragging: false).section(of: row) == .working)

        window.isPointerInSidebar = false
        #expect(window.presentedSections(computed: computed, isDragging: false).section(of: row) == .other)
    }

    /// ⌃⌘1…9 count the window's project's rows as the sidebar draws them:
    /// placing that project alone
    /// (`SidebarPresentedSections.computed(project:…)`) gives what placing
    /// every project (`AppState.sidebarSections(in:)`) gives for it.
    @Test func theWindowsProjectPlacedAlone_isWhatTheSidebarDraws() throws {
        let fixture = Fixture()
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .discovered)
        _ = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .created)
        let project = try #require(fixture.session.project(fixture.a.id))
        let alone = SidebarPresentedSections.computed(
            project: project,
            session: fixture.session,
            window: fixture.primary.id,
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        let every = SidebarPresentedSections.computed(
            projectsOf: fixture.session,
            window: fixture.primary.id,
            windowShowing: { _ in nil },
            queue: AttentionQueue(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil }
        )
        #expect(alone.ordered(project).map(\.row) == every.ordered(project).map(\.row))
        #expect(alone.ordered(project).map(\.section) == every.ordered(project).map(\.section))
        #expect(SessionRowNavigation.workingRows(in: fixture.primary, session: fixture.session, sections: alone)
            == SessionRowNavigation.workingRows(in: fixture.primary, session: fixture.session, sections: every))
    }

    /// With the sidebar hidden, every project placed as it stands
    /// (`AppState.sidebarSections(in:)`) is what the menus count and the
    /// palette reads: a row that came into the working rows since the
    /// sidebar last drew (opened from the palette) is counted, and another
    /// project's other worktrees stay other.
    @Test func withTheSidebarHidden_theRowsAsTheyStand_areCounted() throws {
        let fixture = Fixture()
        let window = fixture.primary
        let worktree = try WorkspaceSessionFixture.appendWorktree(to: fixture.a.id, in: fixture.session, admission: .discovered)
        let row = ContainerID.worktree(projectID: fixture.a.id, worktreeID: worktree.id)
        let elsewhere = try WorkspaceSessionFixture.appendWorktree(to: fixture.b.id, in: fixture.session, admission: .discovered)
        let elsewhereRow = ContainerID.worktree(projectID: fixture.b.id, worktreeID: elsewhere.id)
        let place = {
            let others = fixture.session.otherWindowsByProject(than: window.id)
            return window.presentedSections(computed: .computed(
                projectsOf: fixture.session,
                window: window.id,
                windowShowing: { others[$0] },
                queue: AttentionQueue(),
                pullRequest: { _ in nil },
                gitFacts: { _ in nil }
            ), isDragging: false)
        }
        window.isSidebarPresented = false
        window.present(place())
        #expect(!window.presentedWorkingRows.contains(row))

        fixture.session.setActiveContainer(row, in: window.id, intent: .person)
        window.present(place())

        #expect(window.presentedWorkingRows.contains(row))
        #expect(SessionRowNavigation.workingRows(in: window, session: fixture.session, sections: window.presentedSections).contains(row))
        #expect(window.presentedSections.section(of: elsewhereRow) == .other)
        #expect(SupervisionPaletteFacts(window: window, session: fixture.session).rowSections[elsewhereRow] == .other)
    }

    /// The other windows by the project each shows: the window's own
    /// project is not listed.
    @Test func theOtherWindows_areListedByTheirProjects() throws {
        let fixture = Fixture()
        let other = try fixture.window(showing: fixture.b)

        let others = fixture.session.otherWindowsByProject(than: fixture.primary.id)

        #expect(others == [fixture.b.id: other.id])
        #expect(fixture.session.otherWindowsByProject(than: other.id) == [fixture.a.id: fixture.primary.id])
    }

    // MARK: - Words

    private static func header(
        collapsed: Bool = false,
        working: Int = 3,
        more: Int = 55,
        isInOtherWindow: Bool = false
    ) -> SidebarProjectHeader {
        SidebarProjectHeader(
            id: UUID(),
            name: "weir",
            paletteIndex: nil,
            isCurrent: false,
            isCollapsed: collapsed,
            isInOtherWindow: isInOtherWindow,
            workingCount: working,
            moreCount: more,
            marks: [],
            requestKeys: []
        )
    }

    /// Only a folded header counts, and it counts every row it hides; an
    /// open one leaves the count to its rows and its sections' headings.
    @Test func theCount_showsOnlyWhileFolded_andSumsEveryHiddenRow() {
        #expect(SidebarHeaderText.count(Self.header(), locale: Self.english) == nil)
        #expect(SidebarHeaderText.count(Self.header(more: 0), locale: Self.english) == nil)
        #expect(SidebarHeaderText.count(Self.header(collapsed: true), locale: Self.english) == "58")
        #expect(SidebarHeaderText.count(Self.header(collapsed: true), locale: Self.japanese) == "58")
        #expect(SidebarHeaderText.count(Self.header(collapsed: true, more: 0), locale: Self.english) == "3")
    }

    @Test func voiceOver_readsTheProjectAndItsRows_orThatAnotherWindowShowsIt() {
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(more: 0), locale: Self.english) == "weir, project, 3 worktrees")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(working: 1, more: 0), locale: Self.english) == "weir, project, 1 worktree")
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(), locale: Self.english) == "weir, project, 3 worktrees, 55 more")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(collapsed: true), locale: Self.english) == "weir, project, 3 worktrees, 55 more")
        #expect(SidebarHeaderText
            .accessibilityLabel(Self.header(working: 1), locale: Self.english) == "weir, project, 1 worktree, 55 more")
        #expect(SidebarHeaderText.accessibilityLabel(Self.header(), locale: Self.japanese) == "weir、プロジェクト、ワークツリー 3、ほか 55")
        #expect(
            SidebarHeaderText.accessibilityLabel(Self.header(isInOtherWindow: true), locale: Self.english)
                == "weir, project, shown in another window"
        )
        #expect(
            SidebarHeaderText.accessibilityLabel(Self.header(isInOtherWindow: true), locale: Self.japanese)
                == "weir、プロジェクト、別のウインドウで表示中"
        )
    }

    @Test func theContents_listTheMarksInWords() {
        #expect(SidebarHeaderText.contents([], locale: Self.english) == nil)
        #expect(SidebarHeaderText.contents(["Needs approval", "Running"], locale: Self.english) == "Contains: Needs approval and Running")
        #expect(SidebarHeaderText.contents(["承認待ち"], locale: Self.japanese) == "内訳：承認待ち")
    }

    @Test func thePlusAndTheOtherWindowMark_nameTheProject() {
        #expect(SidebarHeaderText.newWorktree(in: "alpha").resolved(in: Self.english) == "New Worktree in alpha…")
        #expect(SidebarHeaderText.newWorktree(in: "alpha").resolved(in: Self.japanese) == "alpha に新規ワークツリー…")
        #expect(SidebarHeaderText.otherWindowHelp("beta").resolved(in: Self.japanese) == "beta を表示しているウインドウを手前に移動します")
    }
}
