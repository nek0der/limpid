// PaneShellEnvironment.swift
// Limpid — the environment every pty inherits, whichever agent (if any)
// ends up running in it. Split out of `ClaudeShimLocator`, which named one
// agent while assembling the environment for every pane; the agent-specific
// halves stay with their own types and compose over this one.

import Foundation

enum PaneShellEnvironment {
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
        basePath: String
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
        return env
    }

    /// Production assembly, with the shim directories resolved from the
    /// app bundle. Kept next to `variables` so the call site stays one
    /// line and the bundle lookups have exactly one home.
    static func resolved(forPaneID paneID: UUID?) -> [String: String] {
        variables(
            paneID: paneID,
            shimDirectories: [
                ClaudeShimLocator.shimDirectoryURL,
                CodexShimLocator.shimDirectoryURL
            ].compactMap(\.self),
            zdotdir: ClaudeShimLocator.zdotdirURL,
            basePath: ProcessInfo.processInfo.environment["PATH"] ?? fallbackPath
        )
    }

    /// Used when the app was launched without inheriting a `PATH` at all,
    /// which happens under `open(1)` and from Finder.
    static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"
}
