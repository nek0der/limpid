// ReviewTerminalProbeTests.swift
// Limpid — what the destination menu reads in front of each pane, and where it falls back to the surface's own tty.

import Foundation
import Testing
@testable import Limpid

@Suite("Review terminal probe")
struct ReviewTerminalProbeTests {
    private static let binding = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$1", sessionName: "work")

    /// The command in front on each tty, as the kernel would answer.
    private static let inFront = ["/dev/ttys001": "tmux", "/dev/ttys002": "tmux", "/dev/ttys009": "claude"]

    private static func read(
        _ surfaceTTYs: [String],
        clients: [String: TmuxBinding],
        activePaneTTY: @escaping (TmuxBinding) -> String?
    ) -> [String: String] {
        ReviewTerminalProbe.hostedForegrounds(
            surfaceTTYs: surfaceTTYs,
            clients: clients,
            activePaneTTY: activePaneTTY,
            foreground: { inFront[$0] }
        )
    }

    /// Surfaces, whether a tmux client is on the first, and the tty of the
    /// active pane tmux reports for its session, if any.
    struct Probe: Sendable, CustomTestStringConvertible {
        let name: String
        let surfaces: [String]
        let hasClient: Bool
        let activePane: String?
        let expected: [String: String]

        var testDescription: String {
            name
        }
    }

    static let probes = [
        Probe(
            name: "a client's active pane is what is read",
            surfaces: ["/dev/ttys001"],
            hasClient: true,
            activePane: "/dev/ttys009",
            expected: ["/dev/ttys001": "claude"]
        ),
        Probe(
            name: "a surface no client is on reads its own tty",
            surfaces: ["/dev/ttys001", "/dev/ttys002"],
            hasClient: true,
            activePane: "/dev/ttys009",
            expected: ["/dev/ttys001": "claude", "/dev/ttys002": "tmux"]
        ),
        Probe(
            // No clients and no pane to ask for: each surface reads its own
            // tty, as `deliveryTTY` falls back to it when tmux has no client
            // on the tty.
            name: "without tmux every surface reads its own tty",
            surfaces: ["/dev/ttys001", "/dev/ttys002"],
            hasClient: false,
            activePane: nil,
            expected: ["/dev/ttys001": "tmux", "/dev/ttys002": "tmux"]
        ),
        Probe(
            name: "a client whose session has no active pane reads the surface's tty",
            surfaces: ["/dev/ttys001"],
            hasClient: true,
            activePane: nil,
            expected: ["/dev/ttys001": "tmux"]
        )
    ]

    @Test(arguments: probes)
    func eachSurface_readsWhatIsInFrontOfIt_throughTmuxWhereAClientIsOn(_ probe: Probe) {
        let clients = probe.hasClient ? ["/dev/ttys001": Self.binding] : [:]

        #expect(Self.read(probe.surfaces, clients: clients) { _ in probe.activePane } == probe.expected)
    }

    @Test func tmuxsClientsAndActivePanes_areReadFromItsOutput() throws {
        try ReviewValidationScenarios.tmuxDelivery()
    }

    @Test func aSurfaceWithoutTmuxInFront_isDeliveredToByItsOwnTTY() {
        #expect(ReviewTerminalProbe.deliveryTTY(surfaceTTY: "/dev/ttys004", surfaceForeground: "zsh") == "/dev/ttys004")
    }
}

@MainActor
@Suite("Review destination menu's foregrounds")
struct ReviewAgentsForegroundTests {
    @Test func aPaneWithNoTerminalYet_isNotInTheAnswer() async {
        let registry = RecordingSurfaceRegistry()

        let read = await ReviewAgents.foregroundCommands(paneIDs: [UUID(), UUID()], registry: registry)

        #expect(read == [:])
    }

    @Test func aPassCancelled_answersNothing() async {
        let registry = RecordingSurfaceRegistry()
        let pass = Task { @MainActor in
            await ReviewAgents.foregroundCommands(paneIDs: [UUID()], registry: registry)
        }
        pass.cancel()

        #expect(await pass.value == nil)
    }
}
