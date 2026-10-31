// RestoreGateTests.swift
// Weir — when a turn's start may be restored, and what keeps it back.

import Foundation
import Testing
@testable import Weir

struct RestoreGateTests {
    private static func turn(phase: String = "finished", isRecorded: Bool = true) throws -> TurnSummary {
        var extras = TurnSummaryFixture.Extras()
        if isRecorded {
            extras.beginTree = SnapshotTree(tree: TurnSummaryFixture.tree("a", 1), root: "/repo")
        }
        return try TurnSummaryFixture.turn("T1", phase: phase, extras: extras)
    }

    private static func input(
        _ turn: TurnSummary,
        agents: [RestoreGate.Agent] = [],
        isWaiting: Bool = false,
        isRestoring: Bool = false
    ) -> RestoreGate.Input {
        RestoreGate.Input(turn: turn, agents: agents, isWaiting: isWaiting, isRestoring: isRestoring)
    }

    private static func agent(_ provider: AgentKind, _ state: AgentState, isTurnsOwn: Bool = false) -> RestoreGate.Agent {
        RestoreGate.Agent(provider: provider, state: state, isTurnsOwn: isTurnsOwn)
    }

    @Test func aFinishedTurnWithRestingAgents_mayBeRestored() throws {
        let turn = try Self.turn()
        #expect(RestoreGate.blocker(Self.input(turn)) == nil)
        let resting = [Self.agent(.claude, .idle, isTurnsOwn: true), Self.agent(.codex, .finished), Self.agent(.codex, .error)]
        #expect(RestoreGate.blocker(Self.input(turn, agents: resting)) == nil)
    }

    @Test func aTurnWithoutItsStart_cannotBeRestored() throws {
        let turn = try Self.turn(isRecorded: false)
        #expect(RestoreGate.blocker(Self.input(turn)) == .notRecorded)
    }

    @Test func aRunningTurn_isNotRestored() throws {
        let turn = try Self.turn(phase: "started")
        #expect(RestoreGate.blocker(Self.input(turn)) == .turnRunning)
    }

    /// Any agent of the worktree keeps the restore back, not only the
    /// turn's own, and the reason names another one's provider.
    @Test func anAgentAtWorkInTheWorktree_keepsItBack() throws {
        let turn = try Self.turn()
        #expect(
            RestoreGate.blocker(Self.input(turn, agents: [Self.agent(.claude, .running, isTurnsOwn: true)]))
                == .agentRunning(other: nil)
        )
        #expect(RestoreGate.blocker(Self.input(turn, agents: [Self.agent(.codex, .compacting)])) == .agentRunning(other: .codex))
        let both = [Self.agent(.codex, .running), Self.agent(.claude, .running)]
        #expect(RestoreGate.blocker(Self.input(turn, agents: both)) == .agentRunning(other: nil))
    }

    @Test func anAgentWaitingForThePerson_keepsItBack() throws {
        let turn = try Self.turn()
        #expect(RestoreGate.blocker(Self.input(turn, isWaiting: true)) == .agentWaiting)
        #expect(RestoreGate.blocker(Self.input(turn, agents: [Self.agent(.codex, .needsInput)])) == .agentWaiting)
    }

    // MARK: - Who is the worktree's

    private static func runtime(
        _ provider: AgentKind = .claude,
        _ state: AgentState = .running,
        conversation: String = "other",
        panes: Set<UUID> = [],
        root: String?
    ) -> RestoreGate.Runtime {
        RestoreGate.Runtime(
            provider: provider,
            state: state,
            conversation: ConversationKey(provider: provider, conversationID: conversation, isFallback: false),
            paneIDs: panes,
            roots: root.map { [$0] } ?? []
        )
    }

    private static func built(
        _ runtimes: [RestoreGate.Runtime],
        tabPanes: Set<UUID> = [],
        waitingPanes: Set<UUID> = []
    ) throws -> RestoreGate.Input {
        try RestoreGate.input(
            for: turn(),
            facts: RestoreGate.Facts(runtimes: runtimes, worktreeTabPanes: tabPanes, waitingPanes: waitingPanes)
        ) { $0 == "/repo" || $0 == "/link/repo" }
    }

    @Test func anAgentIsTheWorktreesByItsRoot_notByItsTab() throws {
        let tab = UUID()
        let here = Self.runtime(root: "/link/repo")
        let movedAway = Self.runtime(.codex, panes: [tab], root: "/elsewhere")
        let input = try Self.built([here, movedAway], tabPanes: [tab])
        #expect(input.agents.map(\.provider) == [.claude])
    }

    /// Rust holds the restore back when either of a run's roots is the
    /// worktree: its prompt went elsewhere, but its turn here was not ended.
    @Test func anAgentIsTheWorktrees_whenEitherOfItsRootsIs() throws {
        let runtime = RestoreGate.Runtime(
            provider: .codex,
            state: .running,
            conversation: nil,
            paneIDs: [],
            roots: ["/elsewhere", "/repo"]
        )
        #expect(try Self.built([runtime]).agents.map(\.provider) == [.codex])
    }

    @Test func anAgentWithNoRootYet_isTheWorktreesByItsTab() throws {
        let tab = UUID()
        let input = try Self.built(
            [Self.runtime(.codex, panes: [tab], root: nil), Self.runtime(panes: [UUID()], root: nil)],
            tabPanes: [tab]
        )
        #expect(input.agents.map(\.provider) == [.codex])
    }

    @Test func theTurnsOwnConversation_isOwn_whicheverRunResumedIt() throws {
        let own = Self.runtime(conversation: TurnSummaryFixture.conversation.conversationID, root: "/repo")
        let input = try Self.built([own])
        #expect(input.agents.map(\.isTurnsOwn) == [true])
        #expect(RestoreGate.blocker(input) == .agentRunning(other: nil))
    }

    @Test func aWaitCounts_inThePanesOfTheWorktreesAgentsAndTabsOnly() throws {
        let tab = UUID()
        let elsewhereTab = UUID()
        let agentPane = UUID()
        let runtimes = [
            Self.runtime(.claude, .idle, panes: [agentPane], root: "/repo"),
            Self.runtime(.codex, .idle, panes: [elsewhereTab], root: "/elsewhere")
        ]
        #expect(try Self.built(runtimes, tabPanes: [tab], waitingPanes: [agentPane]).isWaiting)
        #expect(try Self.built(runtimes, tabPanes: [tab], waitingPanes: [tab]).isWaiting)
        #expect(try !Self.built(runtimes, tabPanes: [tab, elsewhereTab], waitingPanes: [elsewhereTab]).isWaiting)
        #expect(try !Self.built(runtimes, tabPanes: [tab], waitingPanes: [UUID()]).isWaiting)
    }

    // MARK: - Many turns at once

    /// The changes panel asks for every row. Each path is resolved once for
    /// all of them, not once per row.
    @MainActor
    @Test func aLookup_resolvesEachPathOnce_forEveryTurnItIsAsked() throws {
        var resolutions = 0
        let tabPane = UUID()
        var tabs = (0..<50).map { index in
            RestoreGateLookup.Tab(directory: URL(fileURLWithPath: "/other/\(index)"), panes: [UUID()])
        }
        tabs.append(RestoreGateLookup.Tab(directory: URL(fileURLWithPath: "/link/repo"), panes: [tabPane]))
        let lookup = RestoreGateLookup(
            tabs: tabs,
            runtimes: [Self.runtime(.codex, panes: [tabPane], root: nil), Self.runtime(root: "/link/repo")],
            waitingPanes: [],
            isBusy: { _ in false },
            resolve: { url in
                resolutions += 1
                return url.path == "/link/repo" ? URL(fileURLWithPath: "/repo") : url
            }
        )
        let turn = try Self.turn()
        let inputs = (0..<200).map { _ in lookup.input(for: turn) }

        #expect(inputs.allSatisfy { $0.agents.map(\.provider) == [.codex, .claude] })
        // The turn's root and the fifty-one tab folders; the one agent root,
        // "/link/repo", is also a tab's folder and is not resolved again.
        #expect(resolutions == 52)
    }

    @Test func aRestoreUnderWay_comesFirstAfterTheRecord() throws {
        let turn = try Self.turn(phase: "started")
        #expect(RestoreGate.blocker(Self.input(turn, isRestoring: true)) == .restoring)
        let unrecorded = try Self.turn(isRecorded: false)
        #expect(RestoreGate.blocker(Self.input(unrecorded, isRestoring: true)) == .notRecorded)
    }
}
