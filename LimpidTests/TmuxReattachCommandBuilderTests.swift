// TmuxReattachCommandBuilderTests.swift
// Limpid — pins the command a pane is handed to get back into the tmux
// session it was showing, and the cases where it must decline.

import Foundation
import Testing
@testable import Limpid

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

    /// A legacy binding cannot authenticate its server-scoped id, so its
    /// persistent name is the only safe restore target.
    @Test("legacy bindings use the name instead of an unverified numeric id")
    func initialCommand_legacyBinding_usesName() throws {
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(binding()), paneID: pane)
        )
        #expect(command == "tmux -S '/private/tmp/tmux-501/default' attach -t '=work'")
    }

    @Test("declines when the pane has no binding")
    func initialCommand_noBinding_isNil() {
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab(nil), paneID: pane) == nil)
    }

    /// `initialCommands` is the explicit override that is never
    /// clobbered — `DemoFixture` stages commands through it.
    @Test("declines when a command is already staged for the pane")
    func initialCommand_stagedCommand_isNil() {
        var tab = tab(binding())
        tab.initialCommands[pane] = "echo hello"
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab, paneID: pane) == nil)
    }

    @Test("declines a binding with no target to attach to")
    func initialCommand_emptyIDAndName_isNil() {
        let empty = binding(id: "", name: "")
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab(empty), paneID: pane) == nil)
    }

    @Test("declines a binding with no socket")
    func initialCommand_emptySocket_isNil() {
        let empty = binding(socket: "")
        #expect(TmuxReattachCommandBuilder.initialCommand(for: tab(empty), paneID: pane) == nil)
    }

    /// A name is enough on its own after a server restart drops ids.
    @Test("attaches by name alone when the id is gone")
    func initialCommand_nameOnly_attachesByName() throws {
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(
                for: tab(binding(id: "")), paneID: pane
            )
        )
        #expect(command == "tmux -S '/private/tmp/tmux-501/default' attach -t '=work'")
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
}
