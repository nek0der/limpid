// CommandPaletteTests.swift
// Limpid — the palette's catalog, which rows it offers and enables in a window, and its state opening and closing.

import Foundation
import Testing
@testable import Limpid

@Suite("CommandPalette")
@MainActor
struct CommandPaletteTests {
    /// The rows the palette offers in `window` (the primary by default),
    /// with settings read from a folder of their own.
    private static func items(
        _ session: WorkspaceSession,
        supervision: SupervisionPaletteFacts = .empty,
        window: WindowID? = nil,
        locale: String = "en"
    ) throws -> [CommandPaletteItem] {
        try withTempDir { dir in
            CommandPaletteCatalog.buildItems(
                session: session,
                settings: SettingsStore(directory: dir),
                attention: AttentionState(),
                supervision: supervision,
                window: window ?? session.primaryWindowID,
                locale: Locale(identifier: locale)
            )
        }
    }

    private static func isEnabled(_ action: LimpidShortcutAction, in items: [CommandPaletteItem]) -> Bool? {
        items.first { $0.action == .shortcutAction(action) }?.isEnabled
    }

    // MARK: - Catalog

    /// The palette moves the project the window shows; with none shown
    /// (the project chooser, or a scratch tab only), the moves are off.
    @Test func theProjectMoves_needAShownProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        session.openTab(container: .project(project.id))
        let none = try Self.items(session, supervision: SupervisionPaletteFacts(projectID: nil, sessionRowCount: 1, hasReviewTab: false))
        #expect(Self.isEnabled(.moveProjectUp, in: none) == false)
        #expect(Self.isEnabled(.moveProjectDown, in: none) == false)
        let shown = try Self.items(
            session,
            supervision: SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        )
        #expect(Self.isEnabled(.moveProjectUp, in: shown) == true)
    }

    /// While the review stands where the terminal was, the pane commands
    /// (split right, split down, equalize, and zoom) are off: they would act
    /// on panes nobody sees. Find stays on, and Split Right is back once the
    /// review is hidden again.
    @Test func thePaneCommands_areOffWhileTheReviewHidesThePanes_andBackAfter() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        session.openTab(container: .project(project.id))
        PaneActions.split(session, direction: .horizontal, in: session.primaryWindowID)
        let window = ProjectWindowState(selection: session.primarySelection)
        let paneCommands: [LimpidShortcutAction] = [.splitRight, .splitDown, .equalizeSplits, .toggleSplitZoom]

        let terminal = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        for action in paneCommands {
            #expect(Self.isEnabled(action, in: terminal) == true, "\(action)")
        }

        window.review = ReviewTabState(
            root: "/repo",
            selection: .uncommitted(includesChangesOutsideTurns: false),
            fixedPoint: ReviewTabFixedPoint(),
            agentPaneID: nil,
            destinationPaneID: nil,
            opening: UUID()
        )
        #expect(window.arePanesHidden)
        let review = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        for action in paneCommands {
            #expect(Self.isEnabled(action, in: review) == false, "\(action)")
        }
        #expect(Self.isEnabled(.find, in: review) == true)

        window.review?.isShown = false
        #expect(!window.arePanesHidden)
        let back = try Self.items(session, supervision: SupervisionPaletteFacts(window: window, session: session))
        #expect(Self.isEnabled(.splitRight, in: back) == true)
    }

    /// "#" opens on the projects in the window's sidebar order, and each
    /// one's worktrees in the order its sidebar lists them, before use
    /// re-ranks them.
    @Test func theProjectRows_comeInTheSidebarsOrder() throws {
        let fixture = ProjectWindowsFixture()
        fixture.primary.selection.sidebarArrangement = SidebarArrangement(projectOrder: [fixture.b.id, fixture.c.id])
        let index = try #require(fixture.session.projects.firstIndex { $0.id == fixture.a.id })
        let first = Worktree(label: "first", workingDirectory: URL(fileURLWithPath: "/tmp/a-first"), origin: .gitWorktree)
        let second = Worktree(label: "second", workingDirectory: URL(fileURLWithPath: "/tmp/a-second"), origin: .gitWorktree)
        fixture.session.projects[index].worktrees = [first, second]
        // The sidebar lists `second` before `first` (the other worktrees
        // come after the working ones).
        let order: [ContainerID] = [
            .worktree(projectID: fixture.a.id, worktreeID: second.id),
            .project(fixture.a.id),
            .worktree(projectID: fixture.a.id, worktreeID: first.id)
        ]
        var facts = SupervisionPaletteFacts(projectID: fixture.a.id, sessionRowCount: 3, hasReviewTab: false)
        facts.rowOrder = order

        let items = try Self.items(fixture.session, supervision: facts)
        // The navigation rows only, not Close Project… ("project.close").
        let ids = items.filter { $0.category == .navigate }.map(\.id)
            .filter { $0.hasPrefix("project.") || $0.hasPrefix("worktree.") }

        #expect(ids == [
            "project.\(fixture.b.id.uuidString)",
            "project.\(fixture.c.id.uuidString)",
            "project.\(fixture.a.id.uuidString)",
            "worktree.\(fixture.a.id.uuidString).\(second.id.uuidString)",
            "worktree.\(fixture.a.id.uuidString).\(first.id.uuidString)"
        ])
    }

    @Test("the window's own actions are offered")
    func catalog_offersTheWindowsOwnActions() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        session.openTab(container: .project(project.id))

        let supervision = try Self.items(
            session,
            supervision: SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        )

        for action in [
            LimpidShortcutAction.openFolder,
            .closeWindow,
            .showNeedsAttention,
            .showOpenTabs,
            .focusSidebar,
            .toggleChangesPanel,
            .newWorktree,
            .allProjects,
            .newWindow
        ] {
            #expect(Self.isEnabled(action, in: supervision) == true, "\(action)")
        }
        #expect(Self.isEnabled(.goBack, in: supervision) == session.canNavigateBack(in: session.primaryWindowID))
        #expect(supervision.first { $0.id == "settings.project" }?.action == .openProjectSettings)
        // The detail names whose settings they are.
        #expect(supervision.first { $0.id == "settings.project" }?.subtitle == "limpid")
        // Close Project… is the project ▾'s, and names what it closes.
        #expect(supervision.first { $0.id == "project.close" }?.action == .closeProject)
        #expect(supervision.first { $0.id == "project.close" }?.subtitle == "limpid")
    }

    @Test("a window that shows no project offers no New Worktree, which would have nowhere to go")
    func catalog_newWorktree_needsAShownProject() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()

        let items = try Self.items(session)

        #expect(Self.isEnabled(.newWorktree, in: items) == false)
        #expect(Self.isEnabled(.newWorktreeNow, in: items) == false)
    }

    @Test("a window choosing a project has no pane strip, so it offers no Open Tabs")
    func catalog_showOpenTabs_needsAPaneStrip() throws {
        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        var facts = SupervisionPaletteFacts.empty
        let showing = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.showOpenTabs, in: showing) == true)
        facts.isChoosingProject = true
        let choosing = try Self.items(session, supervision: facts)
        #expect(Self.isEnabled(.showOpenTabs, in: choosing) == false)
    }

    @Test("a window with no project, or one whose project is gone, offers no project rows")
    func catalog_projectRows_needTheProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        func items(projectID: UUID?) throws -> [CommandPaletteItem] {
            try Self.items(session, supervision: SupervisionPaletteFacts(projectID: projectID, sessionRowCount: 0, hasReviewTab: false))
        }

        let scratch = try items(projectID: nil)
        #expect(!scratch.contains { $0.id == "settings.project" })
        #expect(!scratch.contains { $0.id == "project.close" })

        let gone = try items(projectID: UUID())
        #expect(!gone.contains { $0.id == "settings.project" })
        #expect(!gone.contains { $0.id == "project.close" })

        #expect(try items(projectID: project.id).contains { $0.id == "project.close" })
    }

    @Test("the supervision window's rows decide whether their keys are offered")
    func catalog_theWindowsRows_decideWhetherTheirKeysAreOffered() throws {
        let session = WorkspaceSession()
        session.openTab(container: .loose)
        let alone = try Self.items(session, supervision: SupervisionPaletteFacts(projectID: nil, sessionRowCount: 1, hasReviewTab: false))
        let withReview = try Self.items(
            session,
            supervision: SupervisionPaletteFacts(projectID: nil, sessionRowCount: 2, hasReviewTab: true)
        )

        // One tab: nothing to step to, unless the review tab is there.
        #expect(Self.isEnabled(.nextTab, in: alone) == false)
        #expect(Self.isEnabled(.nextTab, in: withReview) == true)
        // One session row: ⌘] has nowhere to go.
        #expect(Self.isEnabled(.nextSession, in: alone) == false)
        #expect(Self.isEnabled(.nextSession, in: withReview) == true)
    }

    @Test("a window's actions read that window's tab")
    func catalog_theWindowsActions_readTheWindowsTab() throws {
        let (session, _, _, tabB, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        session.setActiveTab(tabB.id, in: other)
        PaneActions.split(session, direction: .horizontal, in: other)

        #expect(try Self.isEnabled(.equalizeSplits, in: Self.items(session, window: other)) == true)
        #expect(try Self.isEnabled(.equalizeSplits, in: Self.items(session)) == false)
    }

    @Test("the restore entry names its turn, and is off without one")
    func catalog_restoreEntry_namesItsTurn() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        session.openTab(container: .project(project.id))
        func entry(_ facts: SupervisionPaletteFacts) throws -> CommandPaletteItem? {
            try Self.items(session, supervision: facts, locale: "ja").first { $0.id == "restore.turn" }
        }
        let facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)

        let none = try #require(try entry(facts))
        #expect(!none.isEnabled)
        #expect(none.title == "このターンの前にコードを復元…")
        #expect(none.searchAlias == "Restore Code to Before This Turn…")
        var withTurn = facts
        withTurn.restoreTurnNumber = 5
        let five = try #require(try entry(withTurn))
        #expect(five.isEnabled)
        #expect(five.subtitle == "T5")
        #expect(five.action == .restoreTurn)
    }

    @Test("catalog includes all shortcut actions")
    func catalog_includesAllShortcutActions() throws {
        let items = try Self.items(WorkspaceSession())
        // The actions also hold the window's own rows, such as the restore
        // entry, which are no shortcut.
        let shortcutItems = items.filter { $0.id.hasPrefix("shortcut.") }
        #expect(shortcutItems.count == LimpidShortcutAction.allCases.count)
        #expect(shortcutItems.allSatisfy { $0.category == .actions })
    }

    @Test("the review entries open from any tab")
    func catalog_reviewEntriesFollowTheActiveTab() throws {
        let empty = try Self.items(WorkspaceSession())
        #expect(empty.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == false)
        #expect(empty.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == false)

        let (session, _, _) = WorkspaceSessionFixture.withLooseTab()
        // The review tab says why when there is nothing to read,
        // so a tab with no turn still offers both.
        let items = try Self.items(session)
        #expect(items.first(where: { $0.id == "shortcut.reviewTurn" })?.isEnabled == true)
        #expect(items.first(where: { $0.id == "shortcut.reviewChanges" })?.isEnabled == true)
    }

    @Test("catalog includes open tabs with display titles")
    func catalog_includesOpenTabs() throws {
        let (session, tab, _) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) { $0.titleOverride = "build" }
        let tabItems = try Self.items(session).filter {
            if case .jumpToTab = $0.action {
                return true
            }
            return false
        }
        #expect(tabItems.map(\.title) == ["build"])
    }

    @Test("catalog includes projects")
    func catalog_includesProjects() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let projectItems = try Self.items(session).filter {
            if case let .activateProject(id) = $0.action {
                return id == project.id
            }
            return false
        }
        #expect(projectItems.count == 1)
    }

    /// A worktree is found by the name its row has, its conversation's here
    /// rather than its label, and one only Git reported says it is among the
    /// other worktrees, in the palette's language.
    @Test("a worktree is offered by its row's name, and one Git only reported says so")
    func catalog_namesWorktreesAsTheirRows() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let named = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .created)
        let other = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let tab = session.openTab(
            container: .worktree(projectID: project.id, worktreeID: named.id),
            in: session.primaryWindowID,
            intent: .repair,
            selects: false
        )
        session.update(tab.id) {
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: UUID(),
                conversationID: "c",
                startedAt: Date(timeIntervalSince1970: 0)
            )
        }
        func item(_ worktree: Worktree, locale: String) throws -> CommandPaletteItem? {
            try Self.items(session, locale: locale).first { $0.action == .activateWorktree(projectID: project.id, worktreeID: worktree.id) }
        }

        #expect(try item(named, locale: "en")?.title == "Add tests")
        #expect(try item(named, locale: "en")?.subtitle?.contains("Other Worktrees") == false)
        #expect(try item(other, locale: "en")?.title == other.workingDirectory.lastPathComponent)
        #expect(try item(other, locale: "en")?.subtitle?.hasPrefix("Other Worktrees · ") == true)
        #expect(try item(other, locale: "ja")?.subtitle?.hasPrefix("ほかのワークツリー · ") == true)
    }

    /// With the window's sections, the palette says "other" of the rows the
    /// sidebar lists there, and only those: a worktree only Git reported,
    /// which the sidebar keeps among the working rows, is not.
    @Test("a worktree is called other where the sidebar lists it so")
    func catalog_followsTheSidebarsSections_forOtherWorktrees() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        let waiting = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        let other = try WorkspaceSessionFixture.appendWorktree(to: project.id, in: session, admission: .discovered)
        var facts = SupervisionPaletteFacts(projectID: project.id, sessionRowCount: 1, hasReviewTab: false)
        facts.rowSections = [.worktree(projectID: project.id, worktreeID: other.id): .other]
        func subtitle(_ worktree: Worktree) throws -> String? {
            try Self.items(session, supervision: facts)
                .first { $0.action == .activateWorktree(projectID: project.id, worktreeID: worktree.id) }?.subtitle
        }

        #expect(try subtitle(waiting)?.contains("Other Worktrees") == false)
        #expect(try subtitle(other)?.hasPrefix("Other Worktrees · ") == true)
    }

    // MARK: - State lifecycle

    @Test("opening the palette builds its items from the session, and closing it lets go of them")
    func state_openBuildsItems_andCloseLetsGo() throws {
        let session = WorkspaceSession()
        try withTempDir { dir in
            CommandPaletteActions.openCommandPalette(
                session,
                in: session.primaryWindowID,
                settings: SettingsStore(directory: dir),
                frecencyStore: FrecencyStore(directory: dir),
                attention: AttentionState(),
                supervision: .empty
            )
            let state = try #require(session.commandPaletteState)
            #expect(!state.allItems.isEmpty)

            CommandPaletteActions.closeCommandPalette(session)
            #expect(session.commandPaletteState == nil)
        }
    }
}
