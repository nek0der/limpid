// SessionLaunchStoreTests.swift
// Weir — a new worktree's copy, setup, and what it opens: each stage in order, each failure kept and retried, its notes.

import Foundation
import Testing
@testable import Weir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionLaunchStoreTests {
    typealias Fixture = SessionLaunchFixture

    /// An agent's tab that opened with no pane cannot start its agent: a
    /// failure at that stage, which the row says and "Retry" can take, not
    /// a launch that quietly ends with nothing to say why. A shell's, and
    /// nothing, have no start to wait for either way.
    @Test func anAgentsTabWithNoPane_failsToStart() {
        let pane = UUID()
        let agent = SessionLaunchRequest(open: .agent(.claude))
        #expect(SessionLaunchStore.outcome(of: agent, paneID: pane) == .starting(pane))
        #expect(SessionLaunchStore.outcome(of: agent, paneID: nil) == .failed)
        for other in [SessionLaunchRequest(open: .shell), SessionLaunchRequest(open: .nothing)] {
            #expect(SessionLaunchStore.outcome(of: other, paneID: pane) == .finished)
            #expect(SessionLaunchStore.outcome(of: other, paneID: nil) == .finished)
        }
    }

    /// The request carries an executable for an agent only.
    @Test func aRequestsExecutable_isAnAgentsOnly() {
        #expect(SessionLaunchRequest(open: .agent(.codex), executable: "/x/codex").executable == "/x/codex")
        #expect(SessionLaunchRequest(open: .shell, executable: "/x/codex").executable == nil)
        #expect(SessionLaunchRequest(open: .nothing, executable: "/x/codex").executable == nil)
    }

    @Test func afterTheSetup_theAgentsTabOpens_withNoInstruction_andWaitsForItsStart() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true"), .shorthand("true")])
            fixture.begin(SessionLaunchRequest(open: .agent(.codex)))
            #expect(fixture.store.launch(in: .worktree(projectID: fixture.project.id, worktreeID: fixture.worktree.id)) != nil)
            await pollUntil(timeout: .seconds(10)) { fixture.hasStarted }
            let tab = try #require(fixture.tabs.first)
            let paneID = try #require(tab.splitTree.allLeafIDs().first)
            #expect(tab.initialCommands[paneID] == "codex")
            #expect(tab.initialPromptFiles.isEmpty)
        }
    }

    @Test func aFailedStep_keepsTheStage_andTheRetryRunsFromIt_inTheSameWorktree() async throws {
        try await withTempDir { dir in
            let marker = dir.appendingPathComponent("marker")
            let fixture = try await Fixture.make(in: dir, bootstrap: [
                .shorthand("echo first"),
                .shorthand("test -f '\(marker.path)' || { echo 'missing marker' >&2; exit 3; }")
            ])
            let id = fixture.worktree.id
            fixture.begin()
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches[id]?.failure != nil }
            let failure = try #require(fixture.store.launches[id]?.failure)
            #expect(failure.stage == .setup(stepIndex: 1))
            #expect(failure.logTail == "missing marker")
            #expect(fixture.tabs.isEmpty)

            FileManager.default.createFile(atPath: marker.path, contents: nil)
            fixture.store.retry(worktreeID: id, in: fixture.session)
            #expect(fixture.store.launches[id]?.phase == .settingUp(
                stepIndex: 1,
                stepCount: 2,
                command: "test -f '\(marker.path)' || { echo 'missing marker' >&2; exit 3; }"
            ))
            await pollUntil(timeout: .seconds(10)) { fixture.hasStarted }
            #expect(fixture.tabs.count == 1)
            #expect(fixture.session.project(fixture.project.id)?.worktrees.count == 1)
        }
    }

    @Test func aProjectWithoutSetup_startsTheAgentAtOnce() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            fixture.begin()
            #expect(fixture.hasStarted)
            let tab = try #require(fixture.tabs.first)
            #expect(tab.initialCommands.values.first == "claude")
            #expect(tab.initialPromptFiles.isEmpty)
        }
    }

    /// Asked not to run it, the setup does not run, and the agent opens at once.
    @Test func aSetupNotAskedFor_doesNotRun() async throws {
        try await withTempDir { dir in
            let ran = dir.appendingPathComponent("ran")
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("touch '\(ran.path)'")])
            fixture.begin(SessionLaunchRequest(open: .agent(.claude), runsSetup: false))
            #expect(fixture.hasStarted)
            #expect(fixture.tabs.count == 1)
            try await Task.sleep(for: .milliseconds(100))
            #expect(!FileManager.default.fileExists(atPath: ran.path))
        }
    }

    /// A shell, and nothing, have no CLI to wait 30 seconds for: the launch
    /// ends as the setup does, with a shell's tab or none.
    @Test func aShellOrNothing_endsTheLaunchAtOnce() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            fixture.begin(SessionLaunchRequest(open: .shell))
            #expect(fixture.store.launches.isEmpty)
            #expect(!fixture.store.isFollowing)
            let tab = try #require(fixture.tabs.first)
            #expect(tab.agentsInFront.isEmpty)
            #expect(tab.initialCommands.isEmpty)
        }
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [.shorthand("true")])
            fixture.begin(SessionLaunchRequest(open: .nothing))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.isEmpty }
            #expect(fixture.store.launches.isEmpty)
            #expect(fixture.tabs.isEmpty)
        }
    }

    /// Whether the app follows the panes is the launches alone: there are
    /// no staged instructions to follow any more.
    @Test func following_isTheLaunchesAlone() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            #expect(!fixture.store.isFollowing)
            fixture.begin()
            #expect(fixture.store.isFollowing)
            let paneID = try #require(fixture.store.launches[fixture.worktree.id]?.paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(!fixture.store.isFollowing)
        }
    }

    /// Starts Claude with no setup and returns its pane.
    private static func startAgent(_ fixture: Fixture) throws -> UUID {
        fixture.begin(SessionLaunchRequest(open: .agent(.claude)))
        let launch = try #require(fixture.store.launches[fixture.worktree.id])
        #expect(launch.phase == .starting(isLaunched: false))
        return try #require(launch.paneID)
    }

    @Test func anAgentThatReportsItsStart_endsTheLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let paneID = try Self.startAgent(fixture)
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func anAgentThatNeverReportsItsStart_isTheCLIsStage_untilItDoes() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            let paneID = try Self.startAgent(fixture)
            // Not shown yet: its terminal is not made, and no time runs.
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: false))
            // Nothing to wait for: a stop that never comes. Three times the
            // timeout leaves a stop room to show, were one coming.
            try await Task.sleep(for: .milliseconds(150))
            #expect(fixture.store.launches[id]?.failure == nil)

            // The terminal is made: the staged command is taken.
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches[id]?.phase == .starting(isLaunched: true))
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }
            #expect(fixture.store.launches[id]?.failure?.stage == .startingCLI)

            // Signed in at last: it reports its start, and the stop goes.
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func retryingTheCLIsStage_opensAnotherTab() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            let paneID = try Self.startAgent(fixture)
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) { fixture.store.launches[id]?.failure != nil }

            fixture.store.retry(worktreeID: id, in: fixture.session)
            let launch = try #require(fixture.store.launches[id])
            #expect(launch.phase == .starting(isLaunched: false))
            #expect(launch.paneID != paneID)
            #expect(fixture.tabs.count == 2)
        }
    }

    @Test func closingTheAgentsPane_forgetsTheLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            _ = try Self.startAgent(fixture)
            for tab in fixture.tabs {
                fixture.session.closeTab(tab.id)
            }
            fixture.store.follow(session: fixture.session, agentPanes: [])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func anAgentInFrontThatNeverReports_waitsInItsTerminal_withoutAStop() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            fixture.store.isAgentInFront = { _, agent in agent == .claude }
            let paneID = try Self.startAgent(fixture)
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                fixture.store.launches[id]?.phase == .waitingInTerminal
            }
            #expect(fixture.store.launches[id]?.phase == .waitingInTerminal)
            #expect(fixture.store.launches[id]?.failure == nil)

            // It answered its question and reported its start.
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches.isEmpty)
        }
    }

    @Test func aWaitingAgent_canBeDismissed() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [], startTimeout: .milliseconds(50))
            let id = fixture.worktree.id
            fixture.store.isAgentInFront = { _, _ in true }
            let paneID = try Self.startAgent(fixture)
            // Dismissing applies only to a wait in the terminal, or notes.
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches[id] != nil)
            fixture.session.clearStagedLaunch(paneID: paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [])
            await pollUntil(timeout: .seconds(5), interval: .milliseconds(20)) {
                fixture.store.launches[id]?.phase == .waitingInTerminal
            }
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches.isEmpty)
        }
    }
}

/// What went short without stopping the worktree: said in its bar,
/// kept there once everything ran, until dismissed.
extension SessionLaunchStoreTests {
    @Test func aFetchThatFailed_isKeptAsANote_pastTheEnd_untilDismissed() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let id = fixture.worktree.id
            fixture.begin(SessionLaunchRequest(open: .shell), notes: [.fetch(.failed(start: "main", isLastFetched: false))])
            let launch = try #require(fixture.store.launches[id])
            #expect(launch.phase == .done)
            #expect(launch.notes == [.fetch(.failed(start: "main", isLastFetched: false))])
            #expect(fixture.tabs.count == 1)
            // Not a stop: no failure for the attention list.
            #expect(launch.failure == nil)
            fixture.store.dismiss(worktreeID: id)
            #expect(fixture.store.launches.isEmpty)
        }
    }

    /// An agent's start ends its launch; with a note it stays, done.
    @Test func anAgentWithANote_isDoneOnceItStarts() async throws {
        try await withTempDir { dir in
            let fixture = try await Fixture.make(in: dir, bootstrap: [])
            let id = fixture.worktree.id
            fixture.begin(SessionLaunchRequest(open: .agent(.claude)), notes: [.fetch(.failed(start: "main", isLastFetched: false))])
            let paneID = try #require(fixture.store.launches[id]?.paneID)
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches[id]?.phase == .done)
            // Following it again changes nothing.
            fixture.store.follow(session: fixture.session, agentPanes: [paneID])
            #expect(fixture.store.launches[id]?.phase == .done)
        }
    }

    @Test func noteTexts_sayWhatWentShort() {
        let english = Locale(identifier: "en")
        let japanese = Locale(identifier: "ja")
        #expect(SessionLaunchBar.noteText(.fetch(.failed(start: "main", isLastFetched: false))).resolved(in: english)
            == "Couldn’t fetch from the remote, so the worktree starts from the local main.")
        #expect(SessionLaunchBar.noteText(.fetch(.failed(start: "main", isLastFetched: false))).resolved(in: japanese)
            == "リモートからフェッチできなかったため、ローカルの main から作成します。")
        #expect(SessionLaunchBar.noteText(.copyFailed([".env", "a.key"])).resolved(in: english) == "Couldn’t copy .env, a.key.")
        #expect(SessionLaunchBar.noteText(.copyFailed([".env"])).resolved(in: japanese) == ".env をコピーできませんでした。")
        // A list joins as the language does: no English comma in Japanese.
        #expect(SessionLaunchBar.noteText(.copyFailed([".env", "a.key"])).resolved(in: japanese) == ".env、a.key をコピーできませんでした。")
        #expect(SessionLaunchBar.noteText(.ignoredFilesNotListed).resolved(in: japanese)
            == "Git が無視するファイルを一覧できなかったため、何もコピーしませんでした。")
    }
}

/// The files Git ignores that the project names, copied in before the
/// setup.
extension SessionLaunchStoreTests {
    /// The project's folder with `files` written in it, and the fixture's
    /// project naming `patterns` and Git listing `ignored`.
    private static func withIgnoredFiles(
        in dir: URL,
        files: [String: String],
        patterns: [String],
        ignored: [String],
        bootstrap: [BootstrapItem] = [],
        copyByteLimit: Int64 = IgnoredFileCopier.byteLimit
    ) async throws -> Fixture {
        let root = dir.appendingPathComponent("project")
        let fixture = try await Fixture.make(in: dir, bootstrap: bootstrap, copyByteLimit: copyByteLimit, rootURL: root)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        fixture.session.setProjectIgnoredFilesToCopy(fixture.project.id, to: patterns)
        fixture.git.ignored = ignored
        return fixture
    }

    @Test func theNamedIgnoredFiles_areCopiedIn_beforeTheSetup() async throws {
        try await withTempDir { dir in
            let seen = dir.appendingPathComponent("seen")
            let fixture = try await Self.withIgnoredFiles(
                in: dir,
                files: [".env": "KEY=1", "build/out.o": "x"],
                patterns: [".env"],
                ignored: [".env", "build/"],
                // The setup sees the copy already there.
                bootstrap: [.shorthand("cat .env > '\(seen.path)'")]
            )
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: true))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.isEmpty }
            let worktree = fixture.worktree.workingDirectory
            #expect(try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8) == "KEY=1")
            #expect(!FileManager.default.fileExists(atPath: worktree.appendingPathComponent("build").path))
            #expect(try String(contentsOf: seen, encoding: .utf8) == "KEY=1")
            #expect(fixture.git.operations.contains("ls-files"))
        }
    }

    @Test func theFiles_areNotCopied_whenNotAskedFor() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "KEY=1"], patterns: [".env"], ignored: [".env"])
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: false))
            #expect(fixture.store.launches.isEmpty)
            #expect(!fixture.git.operations.contains("ls-files"))
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    /// Git could not list the ignored files: the bar says so, rather than
    /// the copy passing for one that found nothing, and the setup goes on.
    @Test func aListingThatFails_isSaid_andTheSetupGoesOn() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "KEY=1"], patterns: [".env"], ignored: [".env"])
            fixture.git.nextListIgnoredError = .nonZeroExit(.failure("fatal: index file corrupt"))
            fixture.begin(SessionLaunchRequest(open: .nothing, copiesIgnoredFiles: true))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.values.first?.phase == .done }
            #expect(fixture.store.launches[fixture.worktree.id]?.notes == [.ignoredFilesNotListed])
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    @Test func copiesOverTheLimit_stopAndSaySo() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(
                in: dir,
                files: [".env": String(repeating: "x", count: 64)],
                patterns: [".env"],
                ignored: [".env"],
                copyByteLimit: 16
            )
            fixture.begin(SessionLaunchRequest(open: .nothing, copiesIgnoredFiles: true))
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.values.first?.phase == .done }
            #expect(fixture.store.launches[fixture.worktree.id]?.notes == [.copySkippedOverLimit([".env"], limit: 16)])
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.appendingPathComponent(".env").path))
        }
    }

    /// A worktree deleted while its files are copied leaves no launch
    /// behind saying it copies.
    @Test func aWorktreeGoneDuringTheCopy_endsItsLaunch() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "x"], patterns: [".env"], ignored: [".env"])
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: true))
            try FileManager.default.removeItem(at: fixture.worktree.workingDirectory)
            await pollUntil(timeout: .seconds(10)) { fixture.store.launches.isEmpty }
            #expect(fixture.store.launches.isEmpty)
            #expect(fixture.tabs.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: fixture.worktree.workingDirectory.path))
        }
    }

    /// Deleting the worktree while its files are copied stops the copy
    /// first, as it stops a setup.
    @Test func cancelingTheSetup_alsoStopsACopy() async throws {
        try await withTempDir { dir in
            let fixture = try await Self.withIgnoredFiles(in: dir, files: [".env": "x"], patterns: [".env"], ignored: [".env"])
            fixture.begin(SessionLaunchRequest(open: .shell, copiesIgnoredFiles: true))
            #expect(fixture.store.launches[fixture.worktree.id]?.phase == .copyingFiles)
            await fixture.store.cancelSetup(worktreeID: fixture.worktree.id)
            #expect(fixture.store.launches.isEmpty)
            #expect(fixture.tabs.isEmpty)
        }
    }
}

/// The agent's executable as the new worktree sheet found it
/// (`SessionLaunchRequest.executable`): staged for its one pane, cleared
/// with the staged command, and never saved.
extension SessionLaunchStoreTests {
    private static func open(
        _ request: SessionLaunchRequest,
        store: SessionLaunchStore,
        session: WorkspaceSession,
        project: Project
    ) -> UUID? {
        store.open(request, in: .project(project.id), session: session, window: session.primaryWindowID, intent: .person, selects: true)
    }

    @Test func theSheetsExecutable_reachesItsPanesShell_andIsGoneOnceThePaneIsMade() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let store = SessionLaunchStore(path: { Fixture.path }, git: FakeGit())
        let found = "/Users/someone/.local/share/mise/installs/node/22/bin/codex"
        let paneID = try #require(Self.open(
            SessionLaunchRequest(open: .agent(.codex), executable: found),
            store: store,
            session: session,
            project: project
        ))
        let staged = try #require(PaneHostRepresentable.launch(session: session, paneID: paneID).staged)
        #expect(staged.command == "codex")
        #expect(staged.agentExecutable == AgentInstallation(kind: .codex, executable: found))
        #expect(staged.environment["WEIR_FOUND_CODEX"] == found)
        #expect(staged.environment[InitialPromptFile.environmentKey] == nil)
        #expect(staged.environment["WEIR_FOUND_CLAUDE"] == nil)

        // Saved and read back, as at the next launch, the command stays
        // (it is cleared only once its pane is made) and the path does
        // not: a restored pane searches afresh.
        let tab = try #require(session.tab(containing: paneID))
        let restored = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))
        #expect(restored.initialCommands[paneID] == "codex")
        #expect(restored.initialAgentExecutables.isEmpty)

        session.clearStagedLaunch(paneID: paneID)
        #expect(session.tab(containing: paneID)?.initialAgentExecutables.isEmpty == true)
        #expect(PaneHostRepresentable.launch(session: session, paneID: paneID).staged == nil)
    }

    @Test func anAgentWithoutAnExecutable_isLeftToItsShimsSearch_andAShellStagesNothing() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "demo")
        let store = SessionLaunchStore(path: { Fixture.path }, git: FakeGit())
        let searching = try #require(Self.open(
            SessionLaunchRequest(open: .agent(.codex)),
            store: store,
            session: session,
            project: project
        ))
        #expect(session.stagedLaunch(paneID: searching)?.environment.isEmpty == true)
        let shell = try #require(Self.open(SessionLaunchRequest(open: .shell), store: store, session: session, project: project))
        #expect(session.stagedLaunch(paneID: shell) == nil)
        #expect(Self.open(SessionLaunchRequest(open: .nothing), store: store, session: session, project: project) == nil)
    }
}
