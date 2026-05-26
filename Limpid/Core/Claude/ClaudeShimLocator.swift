// ClaudeShimLocator.swift
// Limpid — resolves the in-bundle `claude-shim/` directory and produces
// the env-var dictionary every pty inherits so a `claude` invocation
// inside Limpid gets intercepted by our shim and routes its hook
// callbacks back to `ClaudeSessionStore`.

import Foundation
import OSLog

private let log = Logger(subsystem: "dev.limpid", category: "claude.shim.locator")

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

    /// Where the hook receiver appends per-pane prompt history.
    /// Mirrors `ClaudePromptStore.directory`; injected for the same
    /// Dev / Release Application-Support reason as the agent-states
    /// dir.
    static var promptsDirectoryURL: URL {
        LimpidPaths.applicationSupportDirectory()
            .appendingPathComponent("claude-prompts", isDirectory: true)
    }

    /// Build the env-var dictionary that `PaneHostView` stages on a
    /// fresh `SurfaceView`. We always inject `LIMPID_PANE_ID` and the
    /// sessions dir (even when `paneID` is nil, the shim itself just
    /// won't do anything useful with an empty pane id). `PATH` is
    /// prepended with the shim dir when we can resolve it; if we
    /// can't (e.g. running from a test bundle without the shim
    /// resource), we leave PATH alone so the user's shell is not
    /// disrupted.
    static func environment(forPaneID paneID: UUID?) -> [String: String] {
        var env: [String: String] = [:]

        if let shim = shimDirectoryURL {
            let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            env["PATH"] = "\(shim.path):\(existingPath)"
            // Expose the shim dir so the `zdotdir/.zshrc` snippet can
            // re-prepend it after the user's `.zshrc` runs. Without
            // that step a user `.zshrc` line like
            // `export PATH="/opt/homebrew/bin:$PATH"` buries the
            // shim past `/opt/homebrew/bin/claude` and the hook
            // never fires.
            env["LIMPID_SHIM_DIR"] = shim.path
            // Redirect zsh's startup-file lookups to our forwarding
            // dir. Each file there sources the user's real one first
            // and `.zshrc` additionally re-prepends LIMPID_SHIM_DIR.
            // Skip the override when the dir is missing (defensive —
            // a corrupted bundle should still launch a usable shell).
            let zdotdir = shim.appendingPathComponent("zdotdir", isDirectory: true)
            if FileManager.default.fileExists(atPath: zdotdir.path) {
                env["ZDOTDIR"] = zdotdir.path
            }
        } else {
            log.debug("claude-shim directory not found in bundle; skipping PATH injection")
        }

        if let id = paneID {
            env["LIMPID_PANE_ID"] = id.uuidString
        }

        env["LIMPID_SESSIONS_DIR"] = sessionsDirectoryURL.path
        env["LIMPID_AGENT_STATES_DIR"] = agentStatesDirectoryURL.path
        env["LIMPID_PROMPTS_DIR"] = promptsDirectoryURL.path
        return env
    }
}
