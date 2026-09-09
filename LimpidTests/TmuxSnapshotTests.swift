// TmuxSnapshotTests.swift
// Limpid — partial observations, restore hints, and pure client joins.

import Foundation
import Testing
@testable import Limpid

@Suite("Tmux snapshot semantics")
@MainActor
struct TmuxSnapshotTests {
    private let path = "/private/tmp/custom socket,one"
    private var binding: TmuxBinding {
        TmuxBinding(socketPath: path, sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false)
    }

    @Test func failedObservation_isNotEmptySuccess() {
        var prior = TmuxTopology(clients: ["/dev/tty1": binding], outcomes: [path: .success("")], observedAt: [path: 0])
        prior.merge(TmuxTopology(outcomes: [path: .timedOut], observedAt: [path: 1]), candidates: [path], now: 1)
        #expect(prior.clients.isEmpty)
        #expect(prior.outcomes[path] == .timedOut)
    }

    @Test func unvisitedServer_expiresOnlyAtSnapshotLifetime() {
        var prior = TmuxTopology(clients: ["/dev/tty1": binding], outcomes: [path: .success("")], observedAt: [path: 0])
        prior.merge(TmuxTopology(), candidates: [path], now: 1)
        #expect(prior.clients.count == 1)
        prior.merge(TmuxTopology(), candidates: [path], now: TmuxTiming.snapshotLifetime + 1)
        #expect(prior.clients.isEmpty)
        #expect(prior.outcomes[path] == nil)
    }

    @Test func customSocketCapture_preservesIdentityAndDistinguishesDetach() throws {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        let frame = TmuxSurfaceSnapshot(paneID: pane, tty: "/dev/tty1", foregroundPID: 10, foregroundName: "tmux")
        session.captureTmuxBindings(surfaces: [frame], bindings: [pane: binding], observedAt: [path: 1], now: 1)
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == binding)
        let encoded = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(TmuxBinding.self, from: encoded) == binding)
        let captured = try #require(session.tab(tab.id))
        let command = try #require(TmuxReattachCommandBuilder.initialCommand(for: captured, paneID: pane))
        #expect(command.contains("if-shell -F"))
        #expect(command.contains("#{pid},42"))
        #expect(command.contains(path))
        session.captureTmuxBindings(surfaces: [frame], bindings: [:], observedAt: [:], now: 2)
        #expect(session.tab(tab.id)?.tmuxBindings[pane]?.isProvisional == true)
        let unresolved = try #require(session.tab(tab.id))
        #expect(TmuxReattachCommandBuilder.initialCommand(for: unresolved, paneID: pane) != nil)
        session.captureTmuxBindings(
            surfaces: [TmuxSurfaceSnapshot(paneID: pane, tty: frame.tty, foregroundPID: 11, foregroundName: "zsh")],
            bindings: [:],
            observedAt: [:],
            now: 3
        )
        #expect(session.tab(tab.id)?.tmuxBindings[pane] == nil)
    }

    @Test func provisionalBinding_neverFallsThroughToNativeResume() throws {
        let (session, tab, pane) = WindowSessionFixture.withLooseTab()
        var provisional = binding
        provisional.isProvisional = true
        session.update(tab.id) {
            $0.tmuxBindings[pane] = provisional
            $0.codexSessions[pane] = AgentSessionInfo(sessionId: UUID().uuidString, cwd: "/tmp")
        }
        let updated = try #require(session.tab(tab.id))
        #expect(CodexResumeCommandBuilder.initialCommand(for: updated, paneID: pane) == nil)
    }

    @Test func ambiguousTTY_isNotAssignedToEitherSurface() {
        let frames = [UUID(), UUID()].map {
            TmuxSurfaceSnapshot(paneID: $0, tty: "/dev/tty1", foregroundPID: 10, foregroundName: "tmux")
        }
        #expect(TmuxPanePresence.resolveClients(frames: frames, clients: ["/dev/tty1": binding]).isEmpty)
    }
}
