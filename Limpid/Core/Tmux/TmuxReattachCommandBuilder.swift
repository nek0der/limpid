// TmuxReattachCommandBuilder.swift
// Limpid — the command that puts a restored pane back into the tmux
// session it was showing when Limpid quit.
//
// Typed into the pane's shell the same way an agent resume is, and for
// the same reason: the pane owns its pty, and handing the command to
// the surface config instead would change its exit semantics.

import Foundation

enum TmuxReattachCommandBuilder {
    /// Command for `paneID`, or `nil` when the pane should just get its
    /// shell.
    ///
    /// Declines when the pane has no binding, when its binding names
    /// nothing reachable, and when the user or `DemoFixture` has staged
    /// a command through `tab.initialCommands` — that slot is the
    /// explicit override, and the same precedence the agent resume
    /// builders observe.
    static func initialCommand(for tab: Tab, paneID: UUID) -> String? {
        guard let binding = tab.tmuxBindings[paneID], !binding.socketPath.isEmpty else {
            return nil
        }
        if let staged = tab.initialCommands[paneID], !staged.isEmpty {
            return nil
        }
        // Id first: it is server-scoped and cannot be handed to a
        // different session. Name second, because ids do not survive a
        // server restart while names do — which is exactly what
        // `tmux-resurrect` and `tmux-continuum` rebuild sessions under.
        // Trying both costs one failed attach in the case where the id
        // is still good.
        let attempts = [binding.sessionID, binding.sessionName]
            .filter { !$0.isEmpty }
            .map { attach(socketPath: binding.socketPath, target: $0) }
        guard let last = attempts.last else { return nil }
        // Only the failed attempts are silenced. If every one of them
        // misses, the session is genuinely gone and tmux's own message
        // is the clearest account of why the pane came back to a shell.
        return attempts.dropLast()
            .map { "\($0) 2>/dev/null || " }
            .joined() + last
    }

    private static func attach(socketPath: String, target: String) -> String {
        "tmux -S \(quoted(socketPath)) attach -t \(quoted(target))"
    }

    /// Single-quoted for `sh`. A session name is user-supplied and tmux
    /// permits a quote in one, so it cannot reach the shell unescaped.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
