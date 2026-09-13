// ClaudeShimLocator.swift
// Limpid — resolves the in-bundle `claude-shim/` directory and produces
// the env-var dictionary every pty inherits so a `claude` invocation
// inside Limpid gets intercepted by our shim and routes its hook
// callbacks back to `ClaudeSessionStore`.

import Foundation
import OSLog

private let log = Logger.limpid("claude.shim.locator")

enum ClaudeShimLocator {
    /// Absolute path of the bundled `claude-shim/` directory, or `nil`
    /// when the bundle does not contain it (e.g. unit-test target with
    /// no Resources phase). Callers treat `nil` as "skip injection" —
    /// the shim is a nice-to-have, never load-bearing.
    static var shimDirectoryURL: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let url = resources.appendingPathComponent("claude-shim", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where the hook receiver writes session records. Mirrors
    /// `ClaudeSessionStore.directory` so the receiver and the Swift
    /// reader land on the same files.
    static var sessionsDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Where the hook receiver writes agent lifecycle records.
    /// Mirrors `ClaudeAgentStateStore.directory` so the receiver and
    /// the Swift watcher land on the same files. Critically: Limpid
    /// Dev vs Release build use different Application Support paths,
    /// so we must inject this rather than let the hook fall back to
    /// the hard-coded "Limpid" default.
    static var agentStatesDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("agent-states", isDirectory: true)
    }

    /// Where the hook receiver writes per-pane `CwdChanged` events.
    /// Mirrors `CwdEventStore.directory` so the receiver and the
    /// Swift watcher meet on the same files. Same Dev/Release path
    /// reasoning as `agentStatesDirectoryURL`.
    static var cwdEventsDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("cwd-events", isDirectory: true)
    }

    /// zsh startup-file forwarding dir, or `nil` when the bundle lacks it.
    /// Each file inside sources the user's real one first and `.zshrc`
    /// additionally re-prepends `LIMPID_SHIM_DIR`. `nil` is defensive: a
    /// corrupted bundle should still launch a usable shell.
    static var zdotdirURL: URL? {
        guard let shim = shimDirectoryURL else { return nil }
        let url = shim.appendingPathComponent("zdotdir", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The Claude-specific half of a pane's environment. `PATH`, `ZDOTDIR`
    /// and `LIMPID_PANE_ID` are not here — they belong to every pane, not
    /// to Claude, and live in `PaneShellEnvironment`.
    ///
    /// The state directories are exported even when `paneID` is nil; the
    /// receiver simply writes nothing useful without a pane to key on.
    static func environment(forPaneID _: UUID?) -> [String: String] {
        var env: [String: String] = [:]
        // Exposed so the `zdotdir/.zshrc` snippet can re-prepend the shim
        // after the user's `.zshrc` runs. Without that step a user line
        // like `export PATH="/opt/homebrew/bin:$PATH"` buries the shim
        // past `/opt/homebrew/bin/claude` and the hook never fires.
        if let shim = shimDirectoryURL {
            env["LIMPID_SHIM_DIR"] = shim.path
        } else {
            log.debug("claude-shim directory not found in bundle; skipping shim dir export")
        }
        // Claude's settings command needs a path without spaces. The shim
        // creates that indirection in TMPDIR, and the bundle id keeps a Dev
        // build from redirecting a Release session's live hook path or vice
        // versa while remaining stable across updates of the same build.
        env["LIMPID_CLAUDE_HOOK_NAMESPACE"] = LimpidPaths.bundleID
        env["LIMPID_SESSIONS_DIR"] = sessionsDirectoryURL.path
        env["LIMPID_AGENT_STATES_DIR"] = agentStatesDirectoryURL.path
        env["LIMPID_CWD_EVENTS_DIR"] = cwdEventsDirectoryURL.path
        return env
    }
}
