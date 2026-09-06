// PaneShellEnvironment.swift
// Limpid — the environment every pty inherits, whichever agent (if any)
// ends up running in it. Split out of `ClaudeShimLocator`, which named one
// agent while assembling the environment for every pane; the agent-specific
// halves stay with their own types and compose over this one.

import Foundation

enum PaneShellEnvironment {
    /// The tmux a hosted agent runs under: which binary, and the socket
    /// name that keeps our server apart from the user's own and from
    /// another Limpid build's.
    struct AgentTmuxHost: Equatable {
        let binary: String
        let socketName: String
    }

    /// Variables shared by every pane: the shim directories that have to
    /// win `PATH` lookups, the startup-file redirect that keeps them there
    /// once the user's own rc has run, and the pane's identity.
    ///
    /// The values are arguments rather than resolved in here. Resolution
    /// goes through `Bundle.main`, which a test bundle cannot satisfy, and
    /// that is the reason this assembly had no coverage before.
    static func variables(
        paneID: UUID?,
        shimDirectories: [URL],
        zdotdir: URL?,
        basePath: String,
        agentTmux: AgentTmuxHost? = nil
    ) -> [String: String] {
        var env: [String: String] = [:]
        // Skipping `PATH` entirely when we have no shim beats exporting one
        // with an empty leading entry: the user's shell should look exactly
        // as it would without Limpid.
        if !shimDirectories.isEmpty {
            env["PATH"] = (shimDirectories.map(\.path) + [basePath])
                .joined(separator: ":")
        }
        if let zdotdir {
            env["ZDOTDIR"] = zdotdir.path
        }
        if let paneID {
            env["LIMPID_PANE_ID"] = paneID.uuidString
        }
        // The binary carries both halves of the decision — that the
        // user asked for tmux hosting, and which tmux to use. A shim
        // that sees it does not have to search for one, and a machine
        // without tmux never sets it, so the shims have a single
        // condition to test rather than a flag plus a lookup.
        if let agentTmux {
            env["LIMPID_AGENT_TMUX"] = agentTmux.binary
            env["LIMPID_AGENT_TMUX_SOCKET"] = agentTmux.socketName
        }
        return env
    }

    /// Production assembly, with the shim directories resolved from the
    /// app bundle. Kept next to `variables` so the call site stays one
    /// line and the bundle lookups have exactly one home.
    static func resolved(
        forPaneID paneID: UUID?,
        hostsAgentsInTmux: Bool = false
    ) -> [String: String] {
        variables(
            paneID: paneID,
            shimDirectories: [
                ClaudeShimLocator.shimDirectoryURL,
                CodexShimLocator.shimDirectoryURL
            ].compactMap(\.self),
            zdotdir: ClaudeShimLocator.zdotdirURL,
            basePath: ProcessInfo.processInfo.environment["PATH"] ?? fallbackPath,
            // Resolved through the same locator the reattach probe uses,
            // so the session a shim creates is one the probe can find.
            agentTmux: hostsAgentsInTmux
                ? TmuxClientProbe.locateTmux().map {
                    AgentTmuxHost(binary: $0, socketName: defaultAgentSocketName())
                }
                : nil
        )
    }

    /// Namespaced by bundle identifier, which is what keeps a Debug
    /// build off a Release build's server. Measured 2026-09-06: a
    /// session created on a server that already exists inherits that
    /// server's environment for every variable outside tmux's
    /// `update-environment`, so a Dev agent started on the Release
    /// build's server would write its hook records into the Release
    /// directories. It also keeps us off a server the user happens to
    /// have started under a plainer name, where our global options
    /// would land on their sessions.
    static func defaultAgentSocketName() -> String {
        "limpid-" + (Bundle.main.bundleIdentifier ?? "unknown")
    }

    /// Used when the app was launched without inheriting a `PATH` at all,
    /// which happens under `open(1)` and from Finder.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
