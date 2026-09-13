// CodexHookInstallerTests.swift
// Limpid — pins the two properties that keep the installer from writing
// somewhere it should not: the default home is inert under the test
// runner, and an injected home still receives the block.

import Foundation
import Testing
@testable import Limpid

@Suite("CodexHookInstaller")
@MainActor
struct CodexHookInstallerTests {
    @Test("executes the signed approval helper directly")
    func approvalHelperCommand_doesNotInvokeShellAsTheExecutable() {
        let command = CodexHookInstaller.executableCommand(
            for: URL(fileURLWithPath: "/Applications/Limpid Dev.app/Contents/MacOS/AgentIntegrationHookHelper")
        )

        #expect(command == "'/Applications/Limpid Dev.app/Contents/MacOS/AgentIntegrationHookHelper'")
        #expect(!command.contains("/bin/sh"))
    }

    /// The installer is the one component that edits a file outside our
    /// own container, and `LimpidApp` refreshes it during bootstrap —
    /// which the Xcode test host also runs. Without this the suite
    /// rewrites the developer's own `~/.codex/config.toml` on every run.
    @Test("keeps the default home off the user's own while under test")
    func defaultUserCodexHome_underTestHost_isNotTheRealHome() {
        let real = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
        #expect(CodexHookInstaller().userCodexHome != real)
    }

    @Test("writes the trust block into an injected home")
    func refresh_injectedHome_writesTrustBlock() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            try "model = \"gpt-5.6-sol\"\n".write(to: config, atomically: true, encoding: .utf8)

            CodexHookInstaller(userCodexHome: home).refresh()

            let written = try String(contentsOf: config, encoding: .utf8)
            #expect(written.hasPrefix("model = \"gpt-5.6-sol\""))
            #expect(written.contains(CodexUserConfig.beginMarker))
            #expect(written.contains("[hooks.state."))
        }
    }

    @Test("keeps PermissionRequest routing stable across repeated refreshes")
    func approvalRouting_isStableAcrossRefreshes() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try "".write(
                to: home.appendingPathComponent("config.toml"),
                atomically: true,
                encoding: .utf8
            )
            let lifecycle = dir.appendingPathComponent("limpid-hook")
            let helper = dir.appendingPathComponent("AgentIntegrationHookHelper")
            #expect(FileManager.default.createFile(atPath: lifecycle.path, contents: Data()))
            #expect(FileManager.default.createFile(
                atPath: helper.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o700]
            ))
            let installer = CodexHookInstaller(
                userCodexHome: home,
                hookScriptURL: lifecycle,
                worktreeHookScriptURL: nil,
                approvalHelperURL: helper
            )
            installer.refresh()

            let initial = installer.environment()["LIMPID_CODEX_HOOK_ARGS"] ?? ""
            #expect(initial.contains("permission-request codex"))

            installer.refresh()
            let firstRefresh = installer.environment()["LIMPID_CODEX_HOOK_ARGS"] ?? ""
            #expect(firstRefresh == initial)

            installer.refresh()
            let secondRefresh = installer.environment()["LIMPID_CODEX_HOOK_ARGS"] ?? ""
            #expect(secondRefresh == initial)

            let trust = try String(
                contentsOf: home.appendingPathComponent("config.toml"),
                encoding: .utf8
            )
            let expectedHash = CodexTrustHash.compute(
                eventLabel: "permission_request",
                command: CodexHookInstaller.executableCommand(for: helper)
                    + " permission-request codex",
                timeoutSec: 600
            )
            #expect(trust.contains(expectedHash))
        }
    }
}
