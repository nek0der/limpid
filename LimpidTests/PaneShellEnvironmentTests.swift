// PaneShellEnvironmentTests.swift
// Limpid — pins the env every pty inherits regardless of which agent runs
// in it. The behaviour lived in `ClaudeShimLocator`, which resolves its
// paths from `Bundle.main` and so could not be exercised from a test
// bundle at all; taking the values as arguments is what makes these
// assertions possible.

import Foundation
import Testing
@testable import Limpid

@Suite("PaneShellEnvironment")
struct PaneShellEnvironmentTests {
    private let base = "/usr/bin:/bin"

    @Test("prepends every shim directory to PATH, in order")
    func variables_prependsShimDirectories() {
        let env = PaneShellEnvironment.variables(
            paneID: nil,
            shimDirectories: [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")],
            zdotdir: nil,
            basePath: base
        )
        #expect(env["PATH"] == "/a:/b:\(base)")
    }

    /// A bundle without the shim resources is the test target's own case,
    /// and the user's shell must come through untouched rather than with
    /// an empty leading entry.
    @Test("leaves PATH alone when there are no shim directories")
    func variables_noShimDirectories_omitsPath() {
        let env = PaneShellEnvironment.variables(
            paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base
        )
        #expect(env["PATH"] == nil)
    }

    @Test("carries the pane id and the startup-file redirect")
    func variables_carriesPaneIDAndZdotdir() {
        let id = UUID()
        let env = PaneShellEnvironment.variables(
            paneID: id,
            shimDirectories: [],
            zdotdir: URL(fileURLWithPath: "/z"),
            basePath: base
        )
        #expect(env["LIMPID_PANE_ID"] == id.uuidString)
        #expect(env["ZDOTDIR"] == "/z")
    }

    @Test("omits the pane id when there is no pane")
    func variables_noPaneID_omitsIt() {
        let env = PaneShellEnvironment.variables(
            paneID: nil, shimDirectories: [], zdotdir: nil, basePath: base
        )
        #expect(env["LIMPID_PANE_ID"] == nil)
        #expect(env["ZDOTDIR"] == nil)
    }
}
