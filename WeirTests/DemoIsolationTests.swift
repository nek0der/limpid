// DemoIsolationTests.swift
// Weir — demo mode touches none of the person's files or repositories, and asks Git nothing.

import Foundation
import Testing
@testable import Weir

@MainActor
struct DemoIsolationTests {
    /// The staged lines leave Claude's T4 and T5, Codex's T1, and the
    /// review's second answer unread, and only them: every other staged turn
    /// reads as viewed. The store is a demo run's, which writes nothing.
    @Test func theStagedViewedLines_leaveOnlyTheStagedTurnsUnread_andWriteNothing() throws {
        try withTempDir { directory in
            let store = ViewedLineStore(directory: directory, writesFiles: false)
            DemoFixture.stagedProjection.markViewedLines(in: store)

            let reminders = try DemoFixture.stagedTurns(of: DemoFixture.remindersConversation)
            #expect(reminders.map(store.isViewed) == [true, true, true, false, false])
            let review = try DemoFixture.stagedTurns(of: DemoFixture.prReviewConversation)
            #expect(review.map(store.isViewed) == [true, false])
            let webhook = try DemoFixture.stagedTurns(of: DemoFixture.webhookConversation)
            #expect(webhook.map(store.isViewed) == [true])
            let codex = try DemoFixture.stagedTurns(of: DemoFixture.remindersCodexConversation)
            #expect(codex.map(store.isViewed) == [false], "unread beside Claude's T4 and T5")
            store.flushSynchronously()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    /// Demo mode runs no pass, so the attention list has items only
    /// because every staged badge becomes one stand-in runtime.
    @Test func aStagedBadge_becomesOneStandInRuntime_andAnItem() {
        let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
        session.update(tab.id) {
            $0.agentBadges[.claude, default: [:]][pane] = AgentBadge(
                state: .finished,
                updatedAt: Date(timeIntervalSince1970: 1000)
            )
        }
        let attention = AttentionState()
        #expect(attention.queueItems(in: session).isEmpty)

        // Demo mode is a process-wide flag, so the seeding it triggers is
        // exercised directly: every staged badge becomes one runtime, in
        // place of the pass demo mode never runs.
        AgentProjectionAdapter.seedRuntimes(fromBadgesIn: session, into: attention)
        let items = attention.queueItems(in: session)
        #expect(items.map(\.subject.paneID) == [pane])
        #expect(attention.allRuntimes.map(\.badge.state) == [.finished])
    }

    /// The runtime demo mode stands in for each agent carries its
    /// conversation, so the selected agent's unread turns are one entry.
    @Test func theStandInRuntime_carriesItsConversation_andItsChangedTurnsAreOneEntry() throws {
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        let attention = AttentionState()
        AgentProjectionAdapter.seedRuntimes(fromBadgesIn: session, into: attention, conversation: DemoFixture.conversation(forPane:))
        let agent = try #require(attention.allRuntimes.first { $0.paneIDs.contains(DemoFixture.Slot.reminders.paneID) })
        #expect(agent.conversation == DemoFixture.remindersConversation)

        let history = Dictionary(uniqueKeysWithValues: DemoFixture.conversations().map { ($0.key, $0.turns) })
        let unread = UnreadTurnRules.byRuntime(attention.allRuntimes.map(UnreadTurnRules.Run.init), history: history) { _ in false }
        // With nothing viewed, the changed turns as one entry, then the answer.
        let entries = try #require(unread[agent.id])
        #expect(entries.map(\.turn.numbers) == [1...5, 3...3])
    }

    /// The demo adapter takes the staged turns as a pass would report them,
    /// and writes nothing.
    @Test func theDemoAdapter_reportsTheStagedTurns() {
        let adapter = AgentProjectionAdapter(writesFiles: false, staged: DemoFixture.stagedProjection)
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        adapter.bootstrap(into: session, attention: AttentionState())
        #expect(adapter.turnHistory.hasLoaded)
        #expect(adapter.turnHistory.turns(of: DemoFixture.remindersConversation).count == 5)
        #expect(adapter.turnHistory.turns(of: DemoFixture.prReviewConversation).count == 2)
    }

    /// The store made with staged facts holds them and asks Git nothing: not
    /// as it starts, not as Weir comes to the front, not for a reading the
    /// person asks for before a move.
    @Test func aStagedGitFactsStore_holdsTheFixturesFacts_andNeverAsksGit() async {
        let store = GitFactsStore(
            fetch: { folder in
                Issue.record("a staged store asked Git about \(folder.path)")
                return .notWorkTree
            },
            staged: DemoFixture.gitFacts
        )
        let session = WorkspaceSession()
        _ = session.restore(from: DemoFixture.snapshot)
        store.start(session: session) { true }
        store.appActivityChanged(isActive: true)
        let targets = PRStatusSyncer.enumerableTargets(session: session)
        await store.refresh(targets, isAll: true)
        await store.refresh(DemoFixture.remindersContainer, at: DemoFixture.selectedWorktreeRoot)
        let read = await store.read(DemoFixture.remindersContainer, at: DemoFixture.selectedWorktreeRoot)
        // A staged store starts no clock and keeps no session, so nothing
        // is left to ask Git later: `start` and the coming to the front
        // return before either could.

        let staged = DemoFixture.gitFacts[DemoFixture.remindersContainer]
        #expect(read == staged.map(GitFactsRead.facts))
        #expect(store.facts == DemoFixture.gitFacts)
        #expect(await store.read(.project(DemoFixture.dotfilesProjectID), at: DemoFixture.dotfilesRoot) == .notWorkTree)
    }

    /// Demo mode restores nothing, discards nothing, and reads no journal:
    /// its worktrees are a fixture's.
    @Test func theInertRestoreBridge_refusesEverything() throws {
        let root = DemoFixture.selectedWorktreeRoot.path
        let bridge = RestoreCoordinator.Bridge.inert
        #expect(try bridge.restore(root, TurnID("T"), "P", []) == .refused(.unknown))
        #expect(try bridge.undo(root, "OP", []) == .refused(.unknown))
        #expect(try bridge.recover(root) == RestoreRecovery(journals: [], settled: []))
        let turns = try DemoFixture.stagedTurns(of: DemoFixture.remindersConversation).suffix(2)
        let range = try #require(ReviewTurnRange(turns: Array(turns)))
        let call = RestoreCoordinator.DiscardCall(range: range, lastTurnNumber: 5, paneID: "P", files: [])
        #expect(try bridge.discard(call, []) == .refused(.unknown))
    }

    /// Demo mode asks Git nothing, and each staged folder is its own
    /// repository, so the changes panel lists the staged turns.
    @Test func gitIsNotAsked_andEachStagedFolderIsItsOwnRepository() async throws {
        let git = WorktreeChanges.Git.inert
        let root = DemoFixture.selectedWorktreeRoot
        #expect(try await git.uncommitted(root).isEmpty)
        #expect(try await git.pathsSince(root, "tree", [:]).paths.isEmpty)
        // A staged turn's own files are unknown, never "none": the panel
        // keeps the turns' lines rather than say they changed no file.
        await #expect(throws: ReviewError.gitFailed) { try await git.pathsBetween(root, "a", "b") }
        let turns = try DemoFixture.stagedTurns(of: DemoFixture.remindersConversation)
        let changes = WorktreeChanges(git: git)
        await changes.loadTurnPaths(turns, root: root)
        #expect(turns.allSatisfy { changes.paths(of: $0.turnID) == nil })

        let roots = RepositoryRoots.staged()
        await roots.resolve(root)
        #expect(roots.answer(for: root) == .repository(path: root.path))
    }
}
