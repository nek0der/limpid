// TmuxBindingMigrationTests.swift
// Limpid — what the launch check makes of the tmux bindings an older state.json carries.

import Foundation
import Testing
@testable import Limpid

/// A socket path on this build's agent server, and one of the user's own.
private enum Sockets {
    static let agent = "/private/tmp/tmux-501/" + PaneShellEnvironment.defaultAgentSocketName()
    static let user = "/private/tmp/tmux-501/default"
}

private func binding(
    socketPath: String,
    sessionID: String = "$1",
    sessionName: String = "limpid-1a2b3c4d-4242",
    pid: String? = "4100",
    startedAt: String? = "1758130000",
    isProvisional: Bool? = nil
) -> TmuxBinding {
    var binding = TmuxBinding(socketPath: socketPath, sessionID: sessionID, sessionName: sessionName)
    binding.serverPID = pid
    binding.serverStartedAt = startedAt
    binding.isProvisional = isProvisional
    return binding
}

private func rows(
    pid: String = "4100",
    startedAt: String = "1758130000",
    sessionID: String = "$1",
    sessionName: String = "limpid-1a2b3c4d-4242"
) -> TmuxServerSessions {
    .sessions([TmuxServerSessionRow(
        serverPID: pid,
        serverStartedAt: startedAt,
        sessionID: sessionID,
        sessionName: sessionName
    )])
}

private let pane = TmuxSessionPane(windowID: "@7", paneID: "%9")

@MainActor
private func planFor(
    session: WindowSession,
    answers: [String: TmuxServerSessions],
    panes: [String: TmuxSessionPane] = [Sockets.agent + "|$1": pane]
) -> TmuxBindingMigration.Plan {
    let claims = TmuxBindingMigration.claims(in: session.tabs)
    return TmuxBindingMigration.plan(tabs: session.tabs, claims: claims, answers: answers, panes: panes)
}

@MainActor
@Suite("Restored tmux bindings are settled once, at launch")
struct TmuxBindingMigrationTests {

    // MARK: - Reading the answer

    @Test func verdict_recordedServerWithTheSession_isLive() {
        let claim = TmuxBindingMigration.Claim(
            tabID: UUID(),
            leafID: UUID(),
            binding: binding(socketPath: Sockets.agent),
            isAgentServer: true
        )
        #expect(TmuxBindingMigration.verdict(for: claim, answer: rows()) == .live(sessionID: "$1"))
    }

    @Test func verdict_anotherServerRun_isGoneWhenTheNameIsNotThere() {
        let claim = TmuxBindingMigration.Claim(
            tabID: UUID(),
            leafID: UUID(),
            binding: binding(socketPath: Sockets.agent),
            isAgentServer: true
        )
        #expect(TmuxBindingMigration.verdict(for: claim, answer: rows(pid: "9999", sessionName: "other")) == .gone)
    }

    @Test func verdict_anotherServerRunWithTheName_offersTheNameOnly() {
        let claim = TmuxBindingMigration.Claim(
            tabID: UUID(),
            leafID: UUID(),
            binding: binding(socketPath: Sockets.user, sessionName: "work"),
            isAgentServer: false
        )
        #expect(
            TmuxBindingMigration.verdict(for: claim, answer: rows(pid: "9999", sessionID: "$4", sessionName: "work"))
                == .namedSessionOnly
        )
    }

    @Test func verdict_noServer_isGone() {
        let claim = TmuxBindingMigration.Claim(
            tabID: UUID(),
            leafID: UUID(),
            binding: binding(socketPath: Sockets.user),
            isAgentServer: false
        )
        #expect(TmuxBindingMigration.verdict(for: claim, answer: .serverGone) == .gone)
    }

    @Test func verdict_hungServer_saysNothing() {
        let claim = TmuxBindingMigration.Claim(
            tabID: UUID(),
            leafID: UUID(),
            binding: binding(socketPath: Sockets.user),
            isAgentServer: false
        )
        #expect(TmuxBindingMigration.verdict(for: claim, answer: .unreachable) == .unknown)
    }

    // MARK: - The plan

    @Test func plan_singlePaneAgentTab_convertsInPlace() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        let plan = planFor(session: session, answers: [Sockets.agent: rows()])
        #expect(plan.drops.isEmpty)
        #expect(plan.conversions.count == 1)
        let conversion = try #require(plan.conversions.first)
        #expect(conversion.leafID == paneID)
        #expect(conversion.needsOwnTab == false)
        #expect(conversion.ref.windowID == "@7")
        #expect(conversion.ref.paneID == "%9")
    }

    @Test func plan_agentPaneInASplitTab_needsItsOwnTab() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        let other = UUID()
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.insert(at: paneID, direction: .horizontal, newID: other).tree
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
        }
        let plan = planFor(session: session, answers: [Sockets.agent: rows()])
        #expect(plan.conversions.map(\.needsOwnTab) == [true])
        #expect(plan.conversions.map(\.leafID) == [paneID])
    }

    @Test func plan_provisionalBindingOnALiveServer_convertsWithoutTheProvisionalMark() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent, isProvisional: true) }
        let conversion = try #require(planFor(session: session, answers: [Sockets.agent: rows()]).conversions.first)
        #expect(conversion.ref.binding.isProvisional == nil)
    }

    @Test func plan_agentServerGone_dropsTheBindingInsteadOfConverting() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        let plan = planFor(session: session, answers: [Sockets.agent: .serverGone])
        #expect(plan.conversions.isEmpty)
        #expect(plan.drops.map(\.leafID) == [paneID])
    }

    @Test func plan_anotherServerRunOnTheAgentSocket_dropsTheBinding() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        // Same session id, a different server run: the pane id a mirror
        // would attach to belongs to someone else now.
        let plan = planFor(session: session, answers: [Sockets.agent: rows(pid: "5555", startedAt: "1758200000")])
        #expect(plan.conversions.isEmpty)
        #expect(plan.drops.map(\.leafID) == [paneID])
    }

    @Test func plan_agentSessionWithoutAPane_dropsTheBinding() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        let plan = planFor(session: session, answers: [Sockets.agent: rows()], panes: [:])
        #expect(plan.conversions.isEmpty)
        #expect(plan.drops.map(\.leafID) == [paneID])
    }

    @Test func plan_userBindingOnALiveSession_isLeftAlone() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work") }
        let plan = planFor(session: session, answers: [Sockets.user: rows(sessionName: "work")])
        #expect(plan.isEmpty)
    }

    @Test func plan_userBindingWhoseServerIsGone_isDropped() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work") }
        let plan = planFor(session: session, answers: [Sockets.user: .serverGone])
        #expect(plan.conversions.isEmpty)
        #expect(plan.drops.map(\.leafID) == [paneID])
    }

    @Test func plan_userBindingOnAHungServer_isKept() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work") }
        #expect(planFor(session: session, answers: [Sockets.user: .unreachable]).isEmpty)
    }

    @Test func plan_withoutTmux_dropsEveryBinding() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user) }
        let claims = TmuxBindingMigration.claims(in: session.tabs)
        #expect(TmuxBindingMigration.planWithoutTmux(claims: claims).drops.map(\.leafID) == [paneID])
    }

    @Test func liveAgentSessions_asksOncePerSession() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        let other = UUID()
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.insert(at: paneID, direction: .horizontal, newID: other).tree
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.tmuxBindings[other] = binding(socketPath: Sockets.agent)
        }
        let claims = TmuxBindingMigration.claims(in: session.tabs)
        let asked = TmuxBindingMigration.liveAgentSessions(claims, answers: [Sockets.agent: rows()])
        #expect(asked.count == 1)
        #expect(asked.first?.sessionID == "$1")
    }

    // MARK: - Applying the plan

    @Test func apply_singlePaneTab_becomesAnAgentMirrorOnTheSameLeaf() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.scrollbackPaths[paneID] = "/tmp/pane.vt"
            t.agentBadges[.claude, default: [:]][paneID] = AgentBadge(state: .running, updatedAt: Date())
        }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: rows()]),
            session: session,
            store: nil
        )
        let migrated = try #require(session.tab(tab.id))
        #expect(migrated.kind == .tmuxMirror)
        #expect(migrated.mirrorOrigin == .agent)
        #expect(migrated.mirroredAgent == .claude)
        #expect(migrated.splitTree.allLeafIDs() == [paneID])
        #expect(migrated.ioSource(for: paneID) == .tmux(TmuxPaneRef(
            binding: binding(socketPath: Sockets.agent),
            windowID: "@7",
            paneID: "%9"
        )))
        #expect(migrated.tmuxBindings.isEmpty)
        // The mirror path never replays a `.vt`, so the file would be left
        // behind unread (design §6 decision 11).
        #expect(migrated.scrollbackPaths.isEmpty)
    }

    @Test func apply_splitTab_movesTheAgentLeafIntoItsOwnMirrorTab() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        let other = UUID()
        let hint = AgentSessionInfo(sessionId: "conv-1", cwd: "/tmp")
        session.update(tab.id) { t in
            t.splitTree = t.splitTree.insert(at: paneID, direction: .horizontal, newID: other).tree
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.scrollbackPaths[paneID] = "/tmp/pane.vt"
            t.scrollbackPaths[other] = "/tmp/other.vt"
            t.agentSessions[.claude, default: [:]][paneID] = hint
        }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: rows()]),
            session: session,
            store: nil
        )
        let source = try #require(session.tab(tab.id))
        #expect(source.kind == .terminal)
        #expect(source.splitTree.allLeafIDs() == [other])
        #expect(source.tmuxBindings.isEmpty)
        // The leaf that stayed keeps its own replay.
        #expect(source.scrollbackPaths[other] == "/tmp/other.vt")

        let mirror = try #require(session.tabs.first { $0.id != tab.id })
        #expect(mirror.kind == .tmuxMirror)
        #expect(mirror.mirrorOrigin == .agent)
        #expect(mirror.mirroredAgent == .claude)
        #expect(mirror.splitTree.allLeafIDs() == [paneID])
        #expect(mirror.agentSessions[.claude]?[paneID] == hint)
        #expect(mirror.tmuxBindings.isEmpty)
        #expect(mirror.scrollbackPaths.isEmpty)
        // Right after the tab it was split out of, and the user's active
        // tab is left as it was.
        #expect(session.tabs.map(\.id) == [tab.id, mirror.id])
        #expect(session.activeTabID == tab.id)
    }

    @Test func apply_dropped_leavesThePaneItsShellAndNothingElse() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.scrollbackPaths[paneID] = "/tmp/pane.vt"
        }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: .serverGone]),
            session: session,
            store: nil
        )
        let migrated = try #require(session.tab(tab.id))
        #expect(migrated.kind == .terminal)
        #expect(migrated.tmuxBindings.isEmpty)
        // A pane that goes back to a shell still replays what it showed.
        #expect(migrated.scrollbackPaths[paneID] == "/tmp/pane.vt")
    }

    @Test func apply_runsOnce_secondPassFindsNothingToDo() {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: rows()]),
            session: session,
            store: nil
        )
        #expect(TmuxBindingMigration.claims(in: session.tabs).isEmpty)
    }

    // MARK: - What the panes are told to run

    @Test func reattach_isNotTypedForAnAgentServer() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.agent) }
        let migrated = try #require(session.tab(tab.id))
        #expect(TmuxReattachCommandBuilder.initialCommand(for: migrated, paneID: paneID) == nil)
    }

    @Test func reattach_isTypedForTheUsersOwnTmux() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work") }
        let migrated = try #require(session.tab(tab.id))
        let command = try #require(TmuxReattachCommandBuilder.initialCommand(for: migrated, paneID: paneID))
        #expect(command.contains(Sockets.user))
        #expect(command.contains("attach-session"))
    }

    @Test func reattach_isNotTypedOnceTheCheckDroppedTheBinding() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { $0.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work") }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.user: .serverGone]),
            session: session,
            store: nil
        )
        let migrated = try #require(session.tab(tab.id))
        #expect(TmuxReattachCommandBuilder.initialCommand(for: migrated, paneID: paneID) == nil)
    }

    @Test func resume_isNotTypedIntoAConvertedLeaf() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "conv-1", cwd: "/tmp")
            t.agentResumeCandidates[paneID] = [.claude]
        }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: rows()]),
            session: session,
            store: nil
        )
        let migrated = try #require(session.tab(tab.id))
        // A mirror leaf resolves no initial command at all: it has no shell
        // of its own (`PaneHostRepresentable.surfaceBacking`).
        #expect(migrated.ioSource(for: paneID) != .local)
        #expect(ClaudeResumeCommandBuilder.initialCommand(for: migrated, paneID: paneID) != nil)
    }

    @Test func resume_isTypedOnceTheCheckDroppedTheBinding() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.agent)
            t.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "conv-1", cwd: "/tmp")
            t.agentResumeCandidates[paneID] = [.claude]
        }
        TmuxMirrorActions.apply(
            planFor(session: session, answers: [Sockets.agent: .serverGone]),
            session: session,
            store: nil
        )
        let migrated = try #require(session.tab(tab.id))
        let command = try #require(ClaudeResumeCommandBuilder.initialCommand(for: migrated, paneID: paneID))
        #expect(command.contains("conv-1"))
    }

    @Test func resume_doesNotRunBesideAReattachOfTheUsersOwnTmux() throws {
        let (session, tab, paneID) = WindowSessionFixture.withLooseTab()
        session.update(tab.id) { t in
            t.tmuxBindings[paneID] = binding(socketPath: Sockets.user, sessionName: "work")
            t.agentSessions[.claude, default: [:]][paneID] = AgentSessionInfo(sessionId: "conv-1", cwd: "/tmp")
            t.agentResumeCandidates[paneID] = [.claude]
        }
        let migrated = try #require(session.tab(tab.id))
        // The reattach wins the precedence in `resolveInitialCommand`, so
        // the pane goes back into tmux rather than starting a second agent.
        let command = try #require(PaneHostRepresentable.resolveInitialCommand(tab: migrated, paneID: paneID))
        #expect(command.hasPrefix("tmux -S"))
    }
}
