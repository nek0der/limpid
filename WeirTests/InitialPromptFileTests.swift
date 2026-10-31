// InitialPromptFileTests.swift
// Weir — an earlier build's first instruction files: none written now, a restored one still delivered, each removed.

import Foundation
import Testing
@testable import Weir

@MainActor
struct InitialPromptFileTests {
    /// A tab opened to run an agent writes no instruction file: the sheet
    /// takes no instruction any more.
    @Test func aNewAgentTab_writesNoInstructionFile() throws {
        /// Every other test here hands in a folder of its own, so only the
        /// tab could change the folder a build writes to. A folder not there
        /// holds nothing.
        func filesWritten() -> Set<String> {
            let names = try? FileManager.default.contentsOfDirectory(atPath: InitialPromptFile.defaultDirectory.path)
            return Set(names ?? [])
        }
        let before = filesWritten()
        let (session, project) = WorkspaceSessionFixture.withProject()
        let container = ContainerID.project(project.id)
        let pane = try #require(TabActions.newTab(session, in: container, running: .claude))
        #expect(session.stagedLaunch(paneID: pane) == WorkspaceSession.StagedLaunch(command: "claude", promptFile: nil))
        let staged = session.tabs.flatMap(\.initialPromptFiles.values)
        #expect(staged.isEmpty)
        #expect(filesWritten() == before)
    }

    /// A tab an earlier build opened behind, restored with its terminal not
    /// made yet, still hands its pane the instruction, and the surface
    /// takes it once (the reader stays for one release).
    @Test func aRestoredTabsInstruction_stillReachesItsPane_once() throws {
        try withTempDir { dir in
            let (session, project) = WorkspaceSessionFixture.withProject()
            let (pane, file) = try InitialPromptFile.restoredTab(
                in: session,
                container: .project(project.id),
                agent: .codex,
                prompt: "do it",
                directory: dir
            )
            let launch = PaneHostRepresentable.launch(session: session, paneID: pane)
            #expect(launch.command == "codex")
            #expect(launch.staged?.promptFile == file)
            #expect(launch.staged?.environment[InitialPromptFile.environmentKey] == file)

            session.clearStagedLaunch(paneID: pane)
            #expect(PaneHostRepresentable.launch(session: session, paneID: pane).staged == nil)
        }
    }

    @Test func closingThePaneBeforeItsAgentStarts_deletesTheInstruction() throws {
        try withTempDir { dir in
            let (session, project) = WorkspaceSessionFixture.withProject()
            let container = ContainerID.project(project.id)
            let (pane, file) = try InitialPromptFile.restoredTab(
                in: session,
                container: container,
                agent: .claude,
                prompt: "do it",
                directory: dir
            )
            let tab = try #require(session.tab(containing: pane))
            session.stageAgentExecutable(AgentInstallation(kind: .claude, executable: "/opt/tools/bin/claude"), paneID: pane)
            #expect(session.stagedLaunch(paneID: pane)?.agentExecutable != nil)

            // A second pane, so closing the first closes a pane, not the tab.
            session.setActiveTab(tab.id)
            PaneActions.split(session, direction: .horizontal)
            session.update(tab.id) { $0.splitTree.focusedLeafID = pane }
            PaneActions.closeActivePane(session, registry: RecordingSurfaceRegistry())
            #expect(session.stagedLaunch(paneID: pane) == nil)
            #expect(!FileManager.default.fileExists(atPath: file))
            #expect(session.tab(tab.id)?.initialAgentExecutables.isEmpty == true)
        }
    }

    @Test func orphans_goAtLaunch_butStagedFilesAndOnesBeingTaken_stay() throws {
        try withTempDir { dir in
            let staged = try InitialPromptFile.stagedByEarlierBuild("keep", in: dir)
            let orphan = try InitialPromptFile.stagedByEarlierBuild("drop", in: dir)
            let taking = dir.appendingPathComponent("\(UUID().uuidString).taken.123")
            FileManager.default.createFile(atPath: taking.path, contents: Data("in flight".utf8))
            let oldTaken = dir.appendingPathComponent("\(UUID().uuidString).taken.456")
            FileManager.default.createFile(atPath: oldTaken.path, contents: Data("left".utf8))
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: -2 * InitialPromptFile.staleAfter)],
                ofItemAtPath: oldTaken.path
            )

            let writing = dir.appendingPathComponent(".\(UUID().uuidString).tmp-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: writing.path, contents: Data("half".utf8))

            // The folder spelled another way (`/var` as `/private/var`)
            // still keeps the staged file.
            InitialPromptFile.removeOrphans(keeping: [staged.resolvingSymlinksInPath().path], in: dir)
            #expect(FileManager.default.fileExists(atPath: writing.path))
            #expect(FileManager.default.fileExists(atPath: staged.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(FileManager.default.fileExists(atPath: taking.path))
            #expect(!FileManager.default.fileExists(atPath: oldTaken.path))
        }
    }
}
