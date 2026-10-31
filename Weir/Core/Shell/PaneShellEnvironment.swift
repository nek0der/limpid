// PaneShellEnvironment.swift
// Weir — the environment every pty inherits, whichever agent (if any)
// ends up running in it. Split out of `ClaudeShimLocator`, which named one
// agent while assembling the environment for every pane; the agent-specific
// halves stay with their own types and compose over this one.

import Foundation

enum PaneShellEnvironment {
    /// The variable that carries the pane's id, which the hook reads to know
    /// it runs in a Weir pane and which one (`PANE_ID_VARIABLE` in the
    /// hook). The two sides check the name against
    /// `rust/fixtures/contract/shared-values.json`.
    static let paneIDVariable = "WEIR_PANE_ID"

    /// The tmux a hosted agent runs under: which binary, and the socket
    /// name that keeps our server apart from the user's own and from
    /// another Weir build's.
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
        agentTmux: AgentTmuxHost? = nil,
        panePathRecord: URL? = nil,
        agentKnownLocations: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [:]
        // Skipping `PATH` entirely when we have no shim beats exporting one
        // with an empty leading entry: the user's shell should look exactly
        // as it would without Weir.
        if !shimDirectories.isEmpty {
            env["PATH"] = (shimDirectories.map(\.path) + [basePath])
                .joined(separator: ":")
        }
        if let zdotdir {
            env["ZDOTDIR"] = zdotdir.path
        }
        if let paneID {
            env[paneIDVariable] = paneID.uuidString
        }
        // The binary carries both halves of the decision — that the
        // user asked for tmux hosting, and which tmux to use. A shim
        // that sees it does not have to search for one, and a machine
        // without tmux never sets it, so the shims have a single
        // condition to test rather than a flag plus a lookup.
        if let agentTmux {
            env["WEIR_AGENT_TMUX"] = agentTmux.binary
            env["WEIR_AGENT_TMUX_SOCKET"] = agentTmux.socketName
        }
        // Where the shell writes the `PATH` it ends up with once the
        // person's `.zshrc` has run: the new worktree sheet looks for the
        // agents on it (`AgentCatalog.detectInstallations`).
        if let panePathRecord {
            env[AgentCatalog.panePathRecordVariable] = panePathRecord.path
        }
        // Where the sheet looks for each agent beyond the `PATH`s. The
        // agent's shim looks there too, so an agent the sheet offers is
        // one the pane can start (`AgentCatalog.knownLocationsEnvironment`).
        env.merge(agentKnownLocations) { _, new in new }
        return env
    }

    /// Production assembly, with the shim directories resolved from the
    /// app bundle. Kept next to `variables` so the call site stays one
    /// line and the bundle lookups have exactly one home.
    /// `projectID` is the project the pane is in, whose `PATH` record its
    /// shell writes; a scratch pane, in none, writes none.
    static func resolved(
        forPaneID paneID: UUID?,
        hostsAgentsInTmux: Bool = false,
        recordsPanePath: Bool = false,
        projectID: UUID? = nil
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
                : nil,
            // Not while the run may not write the person's files (demo
            // mode), as the agents' record directories are not.
            panePathRecord: recordsPanePath
                ? projectID.map { AgentCatalog.panePathRecordURL(in: WeirPaths.applicationSupportDirectory(), project: $0) }
                : nil,
            // The home detection expands them against
            // (`AgentCatalog.detectInstallations`).
            agentKnownLocations: AgentCatalog.knownLocationsEnvironment(home: NSHomeDirectory())
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
        "weir-" + WeirPaths.bundleID
    }

    /// Used when the app was launched without inheriting a `PATH` at all,
    /// which happens under `open(1)` and from Finder.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
