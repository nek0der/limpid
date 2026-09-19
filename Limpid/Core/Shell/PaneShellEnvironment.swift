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

    /// What a new pane is told about hosting its agents in tmux.
    enum AgentTmuxAnswer: Equatable {
        /// An answer the decision needs is not in yet. The pane waits for
        /// it rather than starting its shell (`PaneHostRepresentable`).
        case pending
        /// Its agents run in the pane itself.
        case direct
        /// Its agents run in tmux, shown in a mirror tab.
        case host(AgentTmuxHost)

        /// The host to announce, or `nil` unless the pane is told to host.
        var host: AgentTmuxHost? {
            guard case let .host(host) = self else { return nil }
            return host
        }
    }

    /// Whether a new pane hosts its agents in tmux, runs them directly, or
    /// has to wait until it can be told which.
    ///
    /// Hosting needs three things, and every one of them is what makes a
    /// shim's request reach a tab: the user's opt-in, a tmux a mirror tab can
    /// attach to as the launch probe found it, and a watcher actually reading
    /// the request directory. A shim that is told to host must be able to
    /// rely on a tab opening for its agent, so a pane is never told on an
    /// answer that is not in: the version could have gone down since the
    /// last launch, and a stale answer would have the shim ask for a tab
    /// nothing can open.
    ///
    /// Nor is it told to run its agents directly while the setting is on and
    /// an answer is still out, because the environment is fixed when the
    /// shell starts: every pane a launch restores is created before the
    /// probe answers, and would run its agents directly until it was closed.
    /// Such a pane waits instead, as a leaf whose restored binding is being
    /// checked does, and the probe answers a moment after launch. Reading
    /// cached answers rather than probing here keeps surface creation from
    /// starting a process per pane.
    ///
    /// The directory comes from the intake rather than from a default, so the
    /// one a pane names is by construction the one being read.
    ///
    /// A leaf that came back from tmux runs its agents directly whatever the
    /// setting says (`TmuxConnectionStore.runsAgentsDirectly(inPane:)`). Its
    /// shell starts by resuming the conversation tmux lost (design §5
    /// decision 3), and that resume belongs in the tab the user is looking
    /// at: told to host, the shim would hand it to a second tab, and would
    /// exit successfully as it did, so the resume command's fallback to a
    /// fresh agent could never run when there is nothing to resume. Nor does
    /// such a leaf wait for a pending answer, since none of them changes it.
    static func agentTmuxAnswer(
        hostsAgentsInTmux: Bool,
        support: AgentTmuxSupport,
        intake: AgentMirrorIntake,
        isBackFromTmux: Bool,
        socketName: @autoclosure () -> String = defaultAgentSocketName()
    ) -> AgentTmuxAnswer {
        guard hostsAgentsInTmux, !isBackFromTmux else { return .direct }
        if support == .pending || intake == .pending {
            return .pending
        }
        guard let binary = support.hostBinary,
              let requests = intake.directoryPath
        else { return .direct }
        return .host(AgentTmuxHost(
            binary: binary,
            socketName: socketName(),
            mirrorRequestsDirectory: requests
        ))
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

    /// The whole path `tmux -L <name>` would use for this build's agent
    /// server, physically resolved, which is what a request's socket is
    /// compared against (`AgentMirrorRequest.parse`).
    ///
    /// `TmuxClientProbe.defaultServerDirectory` reads our own `TMUX_TMPDIR`,
    /// and a pane inherits our environment, so the shim's tmux resolves the
    /// name under the same directory. A value the user exports from their
    /// shell rc is the documented blind spot of that lookup, and here it
    /// costs the request rather than pointing us at another server.
    static func defaultAgentSocketPath() -> String {
        TmuxClientProbe.normalizeSocketPath(
            TmuxClientProbe.defaultServerDirectory()
                .appendingPathComponent(defaultAgentSocketName(), isDirectory: false)
                .path
        )
    }

    /// Whether `name` is the agent server of any Limpid build, this one or
    /// another. Every build's name starts with the Release id, since a
    /// Debug id only appends to it.
    static func isAgentSocketName(_ name: String) -> Bool {
        name.hasPrefix(agentSocketPrefix + releaseBundleID)
    }

    /// The same question asked of a whole socket path, which is how every
    /// binding and every pane reference records a server.
    static func isAgentSocketPath(_ path: String) -> Bool {
        isAgentSocketName(URL(fileURLWithPath: path).lastPathComponent)
    }

    private static let agentSocketPrefix = "limpid-"
    private static let releaseBundleID = "dev.limpid.Limpid"

    /// Used when the app was launched without inheriting a `PATH` at all,
    /// which happens under `open(1)` and from Finder.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
