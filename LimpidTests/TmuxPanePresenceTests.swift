// TmuxPanePresenceTests.swift
// Limpid — covers the part of the tmux presence poll that does not need a
// live surface: which panes a tmux session reaches, which pane a client on a
// tty belongs to, which clients are Limpid's agent server, and how a pane's
// job in front is judged from them. The join itself (libghostty's
// foreground pid for a mounted pane) cannot be exercised from a test bundle.

import Darwin
import Foundation
import Testing
@testable import Limpid

@Suite("TmuxPanePresence")
struct TmuxPanePresenceTests {
    @Test("one tmux session projects to every attached Limpid pane")
    func paneIDs_multipleClients_returnsEveryPresentation() {
        let first = UUID()
        let second = UUID()
        let other = UUID()
        let bindings = [
            first: TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work"),
            second: TmuxBinding(socketPath: "/tmp/s", sessionID: "$1", sessionName: "work"),
            other: TmuxBinding(socketPath: "/tmp/s", sessionID: "$2", sessionName: "other")
        ]

        #expect(TmuxPanePresence.paneIDs(
            in: bindings,
            socketPath: "/tmp/s",
            sessionID: "$1",
            aliases: ["/tmp/s": "/private/tmp/s"]
        ) == [first, second])
    }

    /// A resume's deadline takes a tmux client in front for the agent only
    /// on Limpid's own agent server, named per build in tmux's directory;
    /// a session of the person's default server, or of a socket another
    /// build uses, is not ours. `/tmp` and `/private/tmp` are one place.
    @Test("a tmux client is the agent's host only on Limpid's agent server")
    func isAgentHost_onlyOnTheAgentSocket() {
        let directory = URL(fileURLWithPath: "/tmp/tmux-501", isDirectory: true)
        let agentSocket = TmuxPanePresence.agentSocketPath(serverDirectory: directory, socketName: "limpid-dev.limpid.app")
        #expect(agentSocket == "/tmp/tmux-501/limpid-dev.limpid.app")
        let ours = TmuxBinding(
            socketPath: "/private/tmp/tmux-501/limpid-dev.limpid.app",
            sessionID: "$1",
            sessionName: "limpid-1a2b3c4d-42"
        )
        let theirs = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$0", sessionName: "0")
        let otherBuild = TmuxBinding(
            socketPath: "/tmp/tmux-501/limpid-dev.limpid.app.dev",
            sessionID: "$1",
            sessionName: "limpid-1a2b3c4d-7"
        )
        #expect(TmuxPanePresence.isAgentHost(ours, agentSocketPath: agentSocket))
        #expect(!TmuxPanePresence.isAgentHost(theirs, agentSocketPath: agentSocket))
        #expect(!TmuxPanePresence.isAgentHost(otherBuild, agentSocketPath: agentSocket))
    }

    /// No probe has matched the pane's client yet: not Limpid's host.
    @MainActor
    @Test("a pane with no matched client hosts no agent")
    func isAgentHost_withoutAMatchedClient_isFalse() {
        let paneID = UUID()
        let presence = TmuxPanePresence(bindingsByPaneID: [
            paneID: TmuxBinding(socketPath: TmuxPanePresence.agentSocketPath(), sessionID: "$1", sessionName: "limpid")
        ])
        // The binding stands, but no surface showed a tmux client in front.
        #expect(!presence.isAgentHost(inPane: paneID))
        #expect(!presence.isAgentHost(inPane: UUID()))
    }

    /// Two surfaces on one tty cannot be told apart, so the client goes to
    /// neither.
    @MainActor
    @Test func ambiguousTTY_isNotAssignedToEitherSurface() {
        let frames = [UUID(), UUID()].map {
            TmuxSurfaceSnapshot(paneID: $0, tty: "/dev/tty1", foregroundPID: 10, foregroundName: "tmux")
        }
        #expect(TmuxPanePresence.resolveClients(frames: frames, clients: ["/dev/tty1": TmuxBinding(
            socketPath: "/tmp/s", sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false
        )]).isEmpty)
    }
}

/// What the pane's job in front stands for behind a tmux client, judged
/// from the attachment the presence holds (`TmuxPaneJob.inFront(of:inPane:
/// presence:)`), the one judgement a resume's deadline and a pane's badge
/// share. The presence is told which panes show a tmux client through its
/// surfaces, and the person's tmux is a recording stand-in, so no tmux runs.
@MainActor
@Suite("TmuxPaneJob attachment")
struct TmuxPaneJobAttachmentTests {
    private let paneID = UUID()
    private let persons = TmuxBinding(socketPath: "/tmp/tmux-501/default", sessionID: "$3", sessionName: "work")
    private var hosted: TmuxBinding {
        TmuxBinding(socketPath: TmuxPanePresence.agentSocketPath(), sessionID: "$1", sessionName: "limpid-1a2b3c4d-42")
    }

    /// A presence whose surface for `paneID` shows `foreground` in front,
    /// with `binding` the client the last probe matched to it.
    private func makePresence(binding: TmuxBinding?, foreground: @escaping () -> String) -> TmuxPanePresence {
        let paneID = paneID
        let presence = TmuxPanePresence(
            bindingsByPaneID: binding.map { [paneID: $0] } ?? [:],
            surfaces: { [TmuxSurfaceSnapshot(paneID: paneID, tty: "/dev/ttys010", foregroundPID: 10, foregroundName: foreground())] }
        )
        presence.refreshLocalSurfaces()
        return presence
    }

    private final class PersonsTmux {
        var asked: [TmuxBinding] = []
        func read(_ binding: TmuxBinding) -> TmuxPaneJob {
            asked.append(binding)
            return .pane(["zsh"])
        }
    }

    @Test func aClientOfLimpidsAgentServer_isTheAgentsHost_withNoServerAsked() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: hosted) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .agentHost)
        #expect(tmux.asked.isEmpty)
    }

    @Test func aClientOfThePersonsTmux_isAskedForItsActivePane() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: persons) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .pane(["zsh"]))
        #expect(tmux.asked == [persons])
    }

    /// No tmux client in front: nothing to ask, even with an attachment
    /// on record for the pane.
    @Test func noTmuxClientInFront_asksNothing() async {
        let tmux = PersonsTmux()
        let presence = makePresence(binding: hosted) { "tmux" }
        let job = await TmuxPaneJob.inFront(of: ["zsh"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }

    /// The client left the pane since the probe matched it: the job read a
    /// moment before still names tmux, but the attachment the presence held
    /// is gone with the client, so it is neither Limpid's host nor the
    /// person's tmux to ask.
    @Test(arguments: [false, true])
    func anAttachmentTheClientLeft_isNeitherHostNorAsked(isHosted: Bool) async {
        let tmux = PersonsTmux()
        var foreground = "tmux"
        let presence = makePresence(binding: isHosted ? hosted : persons) { foreground }
        foreground = "zsh"
        presence.refreshLocalSurfaces()

        // Dropped, not only hidden: the projection reads the bindings
        // themselves for which panes show a session.
        #expect(presence.bindingsByPaneID[paneID] == nil)
        #expect(presence.client(inPane: paneID) == nil)
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }

    /// A binding no surface backs, as one restored from disk before the
    /// pane's first observation: not an attachment to judge by.
    @Test func aBindingNoSurfaceShows_isNotAnAttachment() async {
        let tmux = PersonsTmux()
        let presence = TmuxPanePresence(bindingsByPaneID: [paneID: hosted])
        let job = await TmuxPaneJob.inFront(of: ["tmux"], inPane: paneID, presence: presence, read: tmux.read)
        #expect(job == .unknown)
        #expect(tmux.asked.isEmpty)
    }
}
