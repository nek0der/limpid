// TmuxReattachCommandBuilderTests.swift
// Weir — pins the command a pane is handed to get back into the tmux
// session it was showing, and the cases where it must decline.

import Foundation
import Testing
@testable import Weir

@Suite("TmuxReattachCommandBuilder")
struct TmuxReattachCommandBuilderTests {
    private let pane = UUID()

    private func tab(_ binding: TmuxBinding?) -> Tab {
        var tab = Tab(title: "t", splitTree: SplitTree(leafID: pane), container: .loose)
        if let binding {
            tab.tmuxBindings[pane] = binding
        }
        return tab
    }

    private func binding(
        socket: String = "/private/tmp/tmux-501/default",
        id: String = "$3",
        name: String = "work"
    ) -> TmuxBinding {
        TmuxBinding(socketPath: socket, sessionID: id, sessionName: name)
    }

    /// A legacy binding cannot authenticate its server-scoped id, and a
    /// server restart drops ids, so either attaches by its persistent name.
    @Test("attaches by name when the id is unverified or gone", arguments: ["$3", ""])
    func initialCommand_withoutAVerifiedID_attachesByName(id: String) throws {
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(binding(id: id)), paneID: pane)
        )
        #expect(command == "tmux -S '/private/tmp/tmux-501/default' attach -t '=work'")
    }

    /// Why a pane gets no reattach.
    enum Decline: CaseIterable, Sendable {
        /// The pane has no binding.
        case noBinding
        /// A command is already staged for the pane: `initialCommands` is
        /// the explicit override that is never clobbered, which
        /// `DemoFixture` stages commands through.
        case stagedCommand
        /// The binding has no target to attach to.
        case noTarget
        /// The binding has no socket.
        case noSocket
    }

    @Test("declines a pane it cannot reattach", arguments: Decline.allCases)
    func initialCommand_declines(_ decline: Decline) {
        var tab: Tab
        switch decline {
        case .noBinding:
            tab = self.tab(nil)
        case .stagedCommand:
            tab = self.tab(binding())
            tab.initialCommands[pane] = "echo hello"
        case .noTarget:
            tab = self.tab(binding(id: "", name: ""))
        case .noSocket:
            tab = self.tab(binding(socket: ""))
        }
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: pane) == nil)
    }

    @Test("a provisional binding still attempts the verified restore targets")
    func initialCommand_provisionalBinding_attemptsRestore() throws {
        var provisional = binding()
        provisional.serverPID = "42"
        provisional.serverStartedAt = "100"
        provisional.isProvisional = true
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(provisional), paneID: pane)
        )
        #expect(command.contains("if-shell -F"))
        #expect(command.contains("attach-session -t"))
    }

    @Test("a restarted server falls back to the persisted session name")
    func initialCommand_verifiedBinding_includesNameFallback() throws {
        var verified = binding()
        verified.serverPID = "42"
        verified.serverStartedAt = "100"
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(verified), paneID: pane)
        )
        #expect(command.contains("attach-session -t '\\''$3'\\'''"))
        #expect(command.contains("attach-session -t '\\''=work'\\'''"))
    }

    @Test("invalid generation data never uses the server-scoped id")
    func initialCommand_invalidGeneration_usesNameOnly() throws {
        var invalid = binding()
        invalid.serverPID = "not-a-pid"
        invalid.serverStartedAt = "100"
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(invalid), paneID: pane)
        )
        #expect(command == "tmux -S '/private/tmp/tmux-501/default' attach -t '=work'")
        #expect(!command.contains("$3"))
    }

    @Test("quotes a fallback name inside both parser layers")
    func initialCommand_verifiedBinding_quotesFallbackName() throws {
        var verified = binding(name: "it's here; display-message unsafe")
        verified.serverPID = "42"
        verified.serverStartedAt = "100"
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(verified), paneID: pane)
        )
        let expected = "tmux -S '/private/tmp/tmux-501/default' if-shell -F "
            + "'#{&&:#{==:#{pid},42},#{==:#{start_time},100}}' "
            + "'attach-session -t '\\''$3'\\''' "
            + "'attach-session -t '\\''=it'\\''\\'\\'''\\''s here; display-message unsafe'\\'''"
        #expect(command == expected)
    }

    /// Everything here reaches a shell, and tmux permits a quote in a
    /// session name.
    @Test("quotes a session name that would otherwise break out")
    func initialCommand_quoteInName_isEscaped() throws {
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(
                for: tab(binding(id: "", name: "it's here; rm -rf /")), paneID: pane
            )
        )
        #expect(command.contains("'=it'\\''s here; rm -rf /'"))
    }

    /// A binding on a socket whose path holds a space and a comma reattaches
    /// to that socket, checking the server's generation first.
    @Test("a custom socket's binding reattaches to that socket, its server checked")
    func initialCommand_customSocket_checksTheServer() throws {
        let path = "/private/tmp/custom socket,one"
        let command = try #require(TmuxReattachCommandBuilder.initialCommand(
            for: tab(TmuxBinding(
                socketPath: path, sessionID: "$1", sessionName: "work", serverPID: "42", serverStartedAt: "100", isProvisional: false
            )),
            paneID: pane
        ))
        #expect(command.contains("if-shell -F"))
        #expect(command.contains("#{pid},42"))
        #expect(command.contains(path))
    }

    /// A binding still provisional after a detach comes back through its
    /// reattach, never as a native resume beside the one tmux may still run.
    @MainActor
    @Test("a provisional binding reattaches instead of resuming natively")
    func provisionalBinding_neverFallsThroughToNativeResume() {
        var tab = tab(TmuxBinding(
            socketPath: "/private/tmp/tmux-501/default", sessionID: "$3", sessionName: "work",
            serverPID: "42", serverStartedAt: "100", isProvisional: true
        ))
        AgentResumeFixture.stage([.codex], on: &tab, paneID: pane, cwd: "/tmp")
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: pane) == nil)
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: pane) != nil)
        tab.tmuxBindings[pane] = nil
        #expect(CodexResumeCommandBuilder.initialCommand(for: tab, paneID: pane) != nil)
    }
}
