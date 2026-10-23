// PaletteExecuteRoutingTests.swift
// Limpid — a committed palette row runs once, in the window whose palette it came from.

import Combine
import Foundation
import Testing
@testable import Limpid

@MainActor
struct PaletteExecuteRoutingTests {
    private static func open(_ session: WorkspaceSession, in windowID: WindowID, directory: URL) {
        CommandPaletteActions.openCommandPalette(
            session,
            in: windowID,
            settings: SettingsStore(directory: directory),
            frecencyStore: FrecencyStore(directory: directory),
            attention: AttentionState(),
            supervision: .empty
        )
    }

    @Test func aRow_runsOnlyInTheWindowItsPaletteOpenedIn() {
        let registry = WindowRegistry(primary: WindowSelection())
        let second = registry.addWindow(WindowSelection())
        var ran: [WindowID] = []
        let tokens = [registry.primary, second].map { window in
            window.commands.requests.sink { request in
                guard case .runPaletteRow = request.command else { return }
                ran.append(window.id)
                request.take()
            }
        }
        defer { tokens.forEach { $0.cancel() } }
        let execution = CommandPaletteExecution(action: .openSettings, windowID: registry.primary.id)

        #expect(registry.perform(.runPaletteRow(execution), in: registry.primary.id))

        #expect(ran == [registry.primary.id])
    }

    @Test func committingARow_asksThePalettesWindow() {
        let windowID = WindowID()
        let state = CommandPaletteState(locale: Locale(identifier: "en"), windowID: windowID)
        let commands = RecordingWindowCommands()

        CommandPaletteActions.postExecution(of: .openSettings, from: state, commands: commands)

        #expect(commands.commands(in: windowID) == [.runPaletteRow(CommandPaletteExecution(action: .openSettings, windowID: windowID))])
    }

    @Test func thePalette_belongsToTheWindowThatOpenedIt_andMovesWhenAnotherAsks() throws {
        let session = WorkspaceSession()
        let other = WindowID()
        try withTempDir { dir in
            Self.open(session, in: session.primaryWindowID, directory: dir)
            let first = try #require(session.commandPaletteState)
            #expect(first.windowID == session.primaryWindowID)

            // Asking again from the same window focuses the open palette.
            Self.open(session, in: session.primaryWindowID, directory: dir)
            #expect(session.commandPaletteState === first)

            // Another window's ask moves it there, with a fresh query.
            Self.open(session, in: other, directory: dir)
            #expect(session.commandPaletteState !== first)
            #expect(session.commandPaletteState?.windowID == other)
        }
    }

    // MARK: - The window a row runs in

    @Test func aPaletteRow_runsInThePalettesWindow() throws {
        let (session, project) = WorkspaceSessionFixture.withProject()
        session.openTab(container: .project(project.id))
        session.setActiveContainer(.loose)
        // The primary stays on its scratch tab, showing no project.
        session.showProject(nil, in: session.primaryWindowID, intent: .person, reason: .person)
        let other = WorkspaceSessionFixture.addWindow(to: session)

        try CommandPaletteActions.runRowForTest(.activateProject(project.id), session: session, window: other)

        #expect(session.selection(other)?.activeContainerID == .project(project.id))
        #expect(session.primarySelection.activeContainerID == .loose)
    }

    @Test(arguments: [
        (CommandPaletteAction.openProjectSettings, WindowCommand.openProjectSettings(nil)),
        (.closeProject, .closeProject(nil))
    ])
    func aProjectRowOfThePalette_isAskedOfThePalettesWindow(row: CommandPaletteAction, command: WindowCommand) throws {
        let (session, _) = WorkspaceSessionFixture.withProject()
        let other = WorkspaceSessionFixture.addWindow(to: session)
        let commands = RecordingWindowCommands()

        try CommandPaletteActions.runRowForTest(row, session: session, window: other, commands: commands)

        #expect(commands.commands(in: other) == [command])
        #expect(commands.commands(in: session.primaryWindowID).isEmpty)
    }

    @Test func aRowTheWindowRunsItself_isNotDispatchedAgain() throws {
        let (session, tabA, _, _, _) = WorkspaceSessionFixture.withTwoLooseTabs()
        var ranInWindow: [LimpidShortcutAction] = []

        try CommandPaletteActions.runRowForTest(.shortcutAction(.nextTab), session: session, window: session.primaryWindowID) { action in
            if case let .shortcutAction(shortcut) = action {
                ranInWindow.append(shortcut)
            }
            return .handled
        }

        #expect(ranInWindow == [.nextTab])
        #expect(session.primarySelection.activeTabID == tabA.id)
    }

    @Test func aRowHandledWithNothingToDo_isNotDispatchedEither() throws {
        let (session, tabA, _, _, _) = WorkspaceSessionFixture.withTwoLooseTabs()

        try CommandPaletteActions.runRowForTest(.shortcutAction(.nextTab), session: session, window: session.primaryWindowID) { _ in
            .handledReturningKeyboard
        }

        #expect(session.primarySelection.activeTabID == tabA.id)
    }
}
