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
    /// Declines when the pane has no binding, when its binding names no
    /// target, and when the user or `DemoFixture` has staged
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
        if let pid = binding.serverPID, let start = binding.serverStartedAt,
           UInt64(pid) != nil, UInt64(start) != nil,
           binding.sessionID.first == "$", UInt64(binding.sessionID.dropFirst()) != nil
        {
            let condition = "#{&&:#{==:#{pid},\(pid)},#{==:#{start_time},\(start)}}"
            let command = tmuxAttachCommand(target: binding.sessionID)
            let fallback = binding.sessionName.isEmpty
                ? ""
                : " \(quoted(tmuxAttachCommand(target: exactNameTarget(binding.sessionName))))"
            // The condition and attach run on the same server connection, so
            // a restarted server cannot receive the old numeric ID. Its
            // restored session may still be found by the persisted name.
            return "tmux -S \(quoted(binding.socketPath)) if-shell -F \(quoted(condition)) \(quoted(command))\(fallback)"
        }
        // Legacy or malformed generation data cannot authenticate a numeric
        // ID. Preserve only the user's named restore intent in that case.
        guard !binding.sessionName.isEmpty else { return nil }
        return attach(socketPath: binding.socketPath, target: exactNameTarget(binding.sessionName))
    }

    private static func attach(socketPath: String, target: String) -> String {
        "tmux -S \(quoted(socketPath)) attach -t \(quoted(target))"
    }

    /// `if-shell` parses each branch as tmux syntax after the outer shell has
    /// removed one quoting layer. The same single-quote form is valid in both
    /// parsers, including the escaped quote sequence used for session names.
    private static func tmuxAttachCommand(target: String) -> String {
        "attach-session -t \(quoted(target))"
    }

    /// Without `=`, tmux falls through from an exact name to prefix and glob
    /// matching. A restore hint must never select a different, similar name.
    private static func exactNameTarget(_ name: String) -> String {
        "=\(name)"
    }

    /// Single-quoted for `sh`. A session name is user-supplied and tmux
    /// permits a quote in one, so it cannot reach the shell unescaped.
    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
