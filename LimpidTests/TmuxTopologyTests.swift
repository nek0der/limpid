// TmuxTopologyTests.swift
// Limpid — what a tmux probe's topology keeps across passes, and which panes
// a run's recorded endpoint finds in it.

import Foundation
import Testing
@testable import Limpid

@Suite("Tmux topology")
struct TmuxTopologyTests {
    private let path = "/private/tmp/custom socket,one"
    private var binding: TmuxBinding {
        TmuxBinding(socketPath: path, sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false)
    }

    /// A run's endpoint as its hook records it.
    private let endpoint = TmuxRuntimeEndpoint(
        socketPath: "/private/tmp/tmux-501/default", serverPID: "42", serverStartedAt: "100", paneID: "%4"
    )

    private func topology(sessionID: String = "$2", start: String = "100") -> TmuxTopology {
        TmuxTopology(panes: TmuxTopology.parsePanes(
            "42\t\(start)\t\(sessionID)\t@3\t%4\t1\t1\n",
            socketPath: "/private/tmp/tmux-501/default"
        ), socketAliases: ["/tmp/tmux-501/default": "/private/tmp/tmux-501/default"])
    }

    /// We keep every unzoomed split visible, but a zoomed pane hides its
    /// neighbors even when their window is active.
    @Test func parsedPanes_distinguishVisibilityFromInputFocus() {
        let output = """
        42\t100\t$1\t@1\t%1\t1\t0\t0
        42\t100\t$1\t@1\t%2\t1\t1\t0
        42\t100\t$1\t@2\t%3\t0\t1\t0
        42\t100\t$2\t@3\t%4\t1\t0\t1
        42\t100\t$2\t@3\t%5\t1\t1\t1
        """
        let panes = TmuxTopology.parsePanes(output, socketPath: path)

        #expect(panes.map(\.paneID) == ["%1", "%2", "%3", "%4", "%5"])
        #expect(panes.map(\.isActive) == [false, true, false, false, true])
        #expect(panes.map(\.isVisible) == [true, true, false, false, true])
    }

    @Test func parsedPanes_olderObservationsLeaveVisibilityUnknown() throws {
        let pane = try #require(TmuxTopology.parsePanes("42\t100\t$1\t@1\t%1\t1\t0\n", socketPath: path).first)

        #expect(!pane.isActive)
        #expect(pane.isVisible == nil)
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

    /// A run's record names its server's start as the hook read it from
    /// `ps`: the kernel's start of the process. tmux's `#{start_time}` is set
    /// a moment later and can be the next second.
    @Test("a record is matched on its server process's start, which tmux's own can trail")
    func locations_matchTheRecordedProcessStart_notTmuxsOwn() {
        let recorded = TmuxRuntimeEndpoint(socketPath: "/tmp/s", serverPID: "42", serverStartedAt: "100", paneID: "%4")
        let byTmux = TmuxRuntimeEndpoint(socketPath: "/tmp/s", serverPID: "42", serverStartedAt: "101", paneID: "%4")
        var topology = TmuxTopology(panes: TmuxTopology.parsePanes("42\t101\t$2\t@3\t%4\t1\t1\n", socketPath: "/tmp/s"))
        // The probe could not read the process: tmux's start stands in.
        #expect(topology.locations(for: recorded).isEmpty)
        #expect(topology.locations(for: byTmux).count == 1)

        topology.panes[0].serverProcessStartedAt = "100"
        #expect(topology.locations(for: recorded).count == 1)
        #expect(topology.locations(for: byTmux).isEmpty)
        // tmux's own start is kept for what compares against tmux's formats.
        #expect(topology.panes[0].serverStartedAt == "101")
    }

    /// A pane tmux moved to another session is still the run's; a server
    /// that reused the pid but started at another time is not its server.
    @Test func topology_followsMovedPaneAndRejectsReusedServerIDs() {
        #expect(topology(sessionID: "$9").locations(for: endpoint).map(\.sessionID) == ["$9"])
        #expect(topology(start: "101").locations(for: endpoint).isEmpty)
        var shared = topology()
        shared.panes += topology(sessionID: "$9").panes
        #expect(shared.locations(for: endpoint).count == 2)
    }
}
