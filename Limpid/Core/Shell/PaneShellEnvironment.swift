// PaneShellEnvironment.swift
// Limpid — the environment every pty inherits, whichever agent (if any)
// ends up running in it. Split out of `ClaudeShimLocator`, which named one
// agent while assembling the environment for every pane; the agent-specific
// halves stay with their own types and compose over this one.

import Foundation

enum PaneShellEnvironment {
    /// The tmux a hosted agent runs under: which binary, the socket name
    /// that keeps our server apart from the user's own and from another
    /// Limpid build's, and where the shim asks this build to open a tab for
    /// the agent (`AgentMirrorRequest`).
    struct AgentTmuxHost: Equatable {
        let binary: String
        let socketName: String
        let mirrorRequestsDirectory: String
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
            env[AgentMirrorRequest.directoryVariable] = agentTmux.mirrorRequestsDirectory
        }
        return env
    }

    /// The tmux host to announce to a new pane, or `nil` when its agents
    /// must run directly.
    ///
    /// Hosting needs both the user's opt-in and a tmux a mirror tab can
    /// attach to, as the launch probe found it. A pane created before the
    /// probe answers is not told to host: a shim that is told must be able
    /// to rely on a tab opening for its agent, and until the probe answers
    /// nothing says one can. Such a pane runs its agents directly, which is
    /// what the setting being off looks like, and panes created afterwards
    /// pick hosting up. Reading a cached answer rather than probing here
    /// keeps surface creation from starting a process per pane.
    static func agentTmuxHost(
        hostsAgentsInTmux: Bool,
        support: AgentTmuxSupport,
        socketName: @autoclosure () -> String = defaultAgentSocketName(),
        mirrorRequestsDirectory: @autoclosure () -> URL = AgentMirrorRequest.defaultDirectory()
    ) -> AgentTmuxHost? {
        guard hostsAgentsInTmux, let binary = support.hostBinary else { return nil }
        return AgentTmuxHost(
            binary: binary,
            socketName: socketName(),
            mirrorRequestsDirectory: mirrorRequestsDirectory().path
        )
    }

    /// Production assembly, with the shim directories resolved from the
    /// app bundle. Kept next to `variables` so the call site stays one
    /// line and the bundle lookups have exactly one home.
    static func resolved(
        forPaneID paneID: UUID?,
        agentTmux: AgentTmuxHost? = nil
    ) -> [String: String] {
        variables(
            paneID: paneID,
            shimDirectories: [
                ClaudeShimLocator.shimDirectoryURL,
                CodexShimLocator.shimDirectoryURL
            ].compactMap(\.self),
            zdotdir: ClaudeShimLocator.zdotdirURL,
            basePath: ProcessInfo.processInfo.environment["PATH"] ?? fallbackPath,
            agentTmux: agentTmux
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
        agentSocketPrefix + LimpidPaths.bundleID
    }

    /// Whether `name` is the agent server of any Limpid build, this one or
    /// another. Every build's name starts with the Release id, since a
    /// Debug id only appends to it.
    static func isAgentSocketName(_ name: String) -> Bool {
        name.hasPrefix(agentSocketPrefix + releaseBundleID)
    }

    private static let agentSocketPrefix = "limpid-"
    private static let releaseBundleID = "dev.limpid.Limpid"

    /// Used when the app was launched without inheriting a `PATH` at all,
    /// which happens under `open(1)` and from Finder.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
