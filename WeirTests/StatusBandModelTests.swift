// StatusBandModelTests.swift
// Weir — the window's bottom band: where the pane in use is, and what runs in it.

import Foundation
import Testing
@testable import Weir

@MainActor
struct StatusBandModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let grid = TerminalGridSize(columns: 120, rows: 40)

    @Test func thePath_namesTheProjectTheCheckoutAndThePane() {
        let model = StatusBandModel(
            .init(
                projectName: "weir",
                checkoutName: "main",
                paneName: "Claude",
                agentName: "Claude Code",
                folder: "~/weir",
                gridSize: Self.grid
            ),
            locale: Self.english
        )
        #expect(model.path == "weir › main › Claude")
        #expect(model.details.map(\.text) == ["Claude Code", "~/weir", "120×40", "UTF-8"])
        // Only the folder gives up its middle in a narrow window.
        #expect(model.details.map(\.isFolder) == [false, true, false, false])
    }

    @Test func aScratchTab_isPlacedInScratch_byItsFolder() {
        let model = StatusBandModel(.init(paneName: "zsh", scratchFolder: "~/notes"), locale: Self.japanese)
        #expect(model.path == "スクラッチ › ~/notes › zsh")
    }

    @Test func theCrumbs_markTheBranchOrFolderAsCode_andDropARepeat() {
        let project = StatusBandModel(
            .init(projectName: "weir", checkoutName: "main", paneName: "Claude"),
            locale: Self.english
        )
        #expect(project.crumbs == [
            .init(text: "weir", isCode: false),
            .init(text: "main", isCode: true),
            .init(text: "Claude", isCode: false)
        ])
        // A shell tab named by its folder: the repeat goes, and the folder
        // it repeated stays code.
        let scratch = StatusBandModel(.init(paneName: "~/notes", scratchFolder: "~/notes"), locale: Self.english)
        #expect(scratch.crumbs == [.init(text: "Scratch", isCode: false), .init(text: "~/notes", isCode: true)])
        #expect(scratch.path == scratch.crumbs.map(\.text).joined(separator: StatusBandModel.crumbSeparator))
    }

    @Test func anUnnamedShell_isCalledShell_ratherThanByItsFolderAgain() {
        // The shell's folder is the project's own: "alpha › main › alpha".
        var input = StatusBandModel.Input(projectName: "alpha", checkoutName: "main", paneName: "alpha", folder: "~/alpha")
        input.isUnnamedShell = true
        #expect(StatusBandModel(input, locale: Self.english).path == "alpha › main › Shell")
        #expect(StatusBandModel(input, locale: Self.japanese).path == "alpha › main › シェル")
        // The folder still shows on the right.
        #expect(StatusBandModel(input, locale: Self.english).details.map(\.text).contains("~/alpha"))
    }

    @Test func aShellThePersonNamed_andAnAgentsPane_keepTheirNames() {
        let named = StatusBandModel(.init(projectName: "alpha", checkoutName: "main", paneName: "server"), locale: Self.english)
        #expect(named.path == "alpha › main › server")
        let agent = StatusBandModel(
            .init(projectName: "alpha", checkoutName: "main", paneName: "Fix the login", agentName: "Claude Code"),
            locale: Self.english
        )
        #expect(agent.path == "alpha › main › Fix the login")
    }

    @Test func theReviewInFront_isWhatTheBandNames() {
        var input = StatusBandModel.Input(
            projectName: "weir",
            checkoutName: "main",
            paneName: "Claude",
            agentName: "Claude Code",
            folder: "~/weir",
            gridSize: Self.grid
        )
        input.isReviewShown = true
        let model = StatusBandModel(input, locale: Self.japanese)
        #expect(model.path == "weir › main › レビュー")
        #expect(model.details.map(\.text) == ["レビュー"])
        #expect(!model.spokenLabel.contains("Claude"))
    }

    @Test func whatIsNotKnown_isLeftOut_andTheEncodingAlwaysShows() {
        // A shell before its directory is known and before it has a grid.
        let model = StatusBandModel(.init(projectName: "weir", paneName: "zsh"), locale: Self.english)
        #expect(model.path == "weir › zsh")
        #expect(model.details.map(\.text) == ["UTF-8"])
    }

    @Test func voiceOver_readsTheSizeInWords() {
        let english = StatusBandModel(.init(projectName: "weir", paneName: "zsh", gridSize: Self.grid), locale: Self.english)
        #expect(english.spokenLabel.contains("120 columns, 40 rows"))
        #expect(!english.spokenLabel.contains("×"))
        let japanese = StatusBandModel(.init(projectName: "weir", paneName: "zsh", gridSize: Self.grid), locale: Self.japanese)
        #expect(japanese.spokenLabel.contains("120 列、40 行"))
    }

    @Test func theInput_isThePaneWithTheKeyboard_inTheWindowsSelectedTab() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = ProjectWindowState(selection: session.primarySelection)
        let tab = session.openTab(container: .project(project.id))
        // Split, with the keyboard in the second leaf: not the first one.
        let first = try #require(tab.splitTree.allLeafIDs().first)
        let split = tab.splitTree.insert(at: first, direction: .horizontal)
        session.update(tab.id) { tab in
            tab.splitTree = split.tree
            tab.splitTree.focusedLeafID = split.newLeafID
        }
        let paneID = split.newLeafID
        var asked: UUID?
        let input = StatusBandModel.input(
            session: session,
            window: window,
            attention: AttentionState(),
            gridSize: { id in
                asked = id
                return Self.grid
            },
            locale: Self.english
        )
        #expect(input.projectName == "weir")
        #expect(input.checkoutName == nil, "a folder with no branch yet")
        // No title of its own yet: the folder it opened in names it.
        #expect(input.paneName == project.rootURL.lastPathComponent)
        #expect(input.agentName == nil)
        #expect(input.isUnnamedShell, "a shell the person has not named")
        #expect(input.gridSize == Self.grid)
        #expect(asked == paneID)
    }

    @Test func aWindowShowingNoTab_namesOnlyThePlace() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let window = ProjectWindowState(selection: session.primarySelection)
        session.selections[window.id]?.projectID = project.id
        let input = StatusBandModel.input(
            session: session,
            window: window,
            attention: AttentionState(),
            gridSize: { _ in Self.grid },
            locale: Self.english
        )
        #expect(input.projectName == "weir")
        #expect(input.paneName == nil)
        #expect(input.gridSize == nil)
        // The encoding is a pane's; with none, the right side states only
        // where the project lives.
        let folder = PathFormatting.abbreviateHome(project.rootURL.path)
        #expect(StatusBandModel(input, locale: Self.english).details == [.init(text: folder, isFolder: true)])
    }
}
