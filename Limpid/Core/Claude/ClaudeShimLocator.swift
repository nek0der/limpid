// ClaudeShimLocator.swift
// Limpid — resolves the in-bundle `claude-shim/` directory and produces
// the env-var dictionary every pty inherits so a `claude` invocation
// inside Limpid gets intercepted by our shim and routes its hook
// callbacks into the record directories the provider descriptor names.

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
        // The variable names come from the provider's install recipe and the
        // directories from its descriptor, so the receiver writes exactly
        // where the projection reads. The bundle id among them keeps a Dev
        // build from redirecting a
        // Release session's live hook path or vice versa, while staying stable
        // across updates of the same build.
        let directories = AgentProviderRegistry.directories(
            under: LimpidPaths.applicationSupportDirectory()
        )[AgentKind.claude.rawValue]
        if let directories {
            env.merge(AgentProviderRegistry.environment(
                for: AgentKind.claude.rawValue,
                state: directories.state,
                sessions: directories.sessions,
                cwdEvents: directories.cwdEvents
            )) { _, recipe in recipe }
        } else {
            // Without a descriptor we have no name for the directories, and
            // the projection reads none either, so guessing one would only
            // scatter records nobody collects.
            log.error("claude provider directories unavailable; exporting no record directories")
        }
        env.merge(AgentHookBackend.environment) { _, backend in backend }
        return env
    }
}
