// AgentTmuxSupport.swift
// Limpid — whether this machine's tmux is one we can show a hosted agent in.

import Foundation

/// What the launch probe found out about the tmux a hosted agent would run
/// under.
///
/// A hosted agent is shown in a mirror tab, and a mirror cannot attach to a
/// server older than `TmuxMirrorTarget.minimumVersion`. So the version is part
/// of the condition for telling a shim to host an agent at all: a shim that is
/// told to host is guaranteed a tab can be opened for it, and needs no timeout
/// or fallback of its own for the case where one cannot.
enum AgentTmuxSupport: Equatable {
    /// The probe has not answered yet.
    case pending
    /// No tmux in any place we look for one.
    case notInstalled
    /// tmux is there, but `tmux -V` failed or printed something we cannot
    /// read, so nothing says a mirror could attach to it.
    case unreadableVersion(binary: String)
    /// tmux is older than a mirror accepts.
    case unsupported(binary: String, version: TmuxVersion)
    case supported(binary: String, version: TmuxVersion)

    /// The binary a hosted agent may use, or `nil` unless the version is one
    /// a mirror accepts. The only answer the environment reads.
    var hostBinary: String? {
        guard case let .supported(binary, _) = self else { return nil }
        return binary
    }

    /// Whether the setting that offers a tmux tab can be switched on. A
    /// pending probe reads as available rather than as a refusal: it answers
    /// within a moment of launch, and a pane opened in the meantime waits for
    /// it (`PaneShellEnvironment.agentTmuxAnswer`). Every other answer means
    /// no tab could be opened, so the setting is disabled and the pane says
    /// which answer it was.
    var allowsHostingSetting: Bool {
        switch self {
        case .pending, .supported: true
        case .notInstalled, .unreadableVersion, .unsupported: false
        }
    }

    /// Why this Mac's tmux rules a mirror tab's reconnect out, or nil when
    /// tmux is not what stands in the way. Short enough to trail a menu
    /// item's title: a disabled item shows no tooltip, so the reason has to
    /// be part of what is drawn.
    ///
    /// The three answers are named apart for the reason the connection card
    /// names them apart: a Mac with an old tmux must not be told it has
    /// none. A pending probe reads as no obstacle, as it does everywhere
    /// else — it answers within a moment of launch.
    var reconnectObstacle: String? {
        switch self {
        case .pending, .supported:
            nil
        case .notInstalled:
            String(localized: "no tmux found")
        case .unreadableVersion:
            String(localized: "unreadable tmux version")
        case .unsupported:
            String(localized: "needs tmux \(TmuxMirrorTarget.minimumVersion.description) or newer")
        }
    }

    /// Classifies what was found. Pure, so each outcome is testable without a
    /// tmux on the machine.
    static func evaluate(binary: String?, versionOutput: TmuxCommandResult?) -> AgentTmuxSupport {
        guard let binary else { return .notInstalled }
        guard case let .success(text) = versionOutput,
              let version = TmuxProtocol.parseVersion(text)
        else { return .unreadableVersion(binary: binary) }
        return version >= TmuxMirrorTarget.minimumVersion
            ? .supported(binary: binary, version: version)
            : .unsupported(binary: binary, version: version)
    }

    /// Runs `tmux -V` on the binary `TmuxClientProbe.locateTmux` picks, which
    /// is the binary a hosted agent is then told to use.
    ///
    /// A dispatch queue for the same reason as `TmuxSessionProbe.check`: the
    /// probe blocks on a child process. The two closures are there so a test
    /// can decide what is installed without starting a process.
    nonisolated static func probe(
        locate: @escaping @Sendable () -> String? = { TmuxClientProbe.locateTmux() },
        readVersion: @escaping @Sendable (String) -> TmuxCommandResult = AgentTmuxSupport.readVersion(binary:)
    ) async -> AgentTmuxSupport {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let binary = locate()
                continuation.resume(returning: evaluate(binary: binary, versionOutput: binary.map(readVersion)))
            }
        }
    }

    /// The probe runs while the application is launching, when the binary may
    /// not be in the page cache yet, so it gets the whole poll budget rather
    /// than the half second a query against a running server does.
    nonisolated static func readVersion(binary: String) -> TmuxCommandResult {
        TmuxCommand().run(executable: binary, arguments: ["-V"], timeout: TmuxTiming.pollBudget)
    }
}
