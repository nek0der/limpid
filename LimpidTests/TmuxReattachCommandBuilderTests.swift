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

    /// Id first, name second. Ids are server-scoped and cannot be
    /// reused; names survive a server restart, which is what
    /// `tmux-resurrect` and `tmux-continuum` rebuild sessions under.
    /// Trying both costs one failed attach and covers both worlds.
    @Test("attaches by session id, falling back to the name")
    func initialCommand_binding_triesIDThenName() throws {
        let command = try #require(
            TmuxReattachCommandBuilder.initialCommand(for: tab(binding()), paneID: pane)
        )
        #expect(command == """
        tmux -S '/private/tmp/tmux-501/default' attach -t '$3' 2>/dev/null \
        || tmux -S '/private/tmp/tmux-501/default' attach -t 'work'
        """)
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
        #expect(command == "tmux -S '/private/tmp/tmux-501/default' attach -t 'work'")
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
        #expect(command.contains("'it'\\''s here; rm -rf /'"))
    }
}
