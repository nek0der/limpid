// CodexHookInstallerTests.swift
// Weir — pins what keeps the installer from writing somewhere it should
// not, or over what it could not read: the default home is inert under the
// test runner, the tables an earlier build wrote leave an injected home's
// config, a config it cannot read or decode is left alone, and a linked
// config is written through its link.

import Foundation
import Testing
@testable import Weir

@Suite("CodexHookInstaller")
@MainActor
struct CodexHookInstallerTests {
    private let theirs = "model = \"gpt-5.6-sol\"\n"

    /// `theirs` with the block an earlier build appended to it.
    private var withLegacyBlock: String {
        theirs + "\n" + CodexUserConfig.beginMarker + """

        [hooks.state."/<session-flags>/config.toml:stop:0:0"]
        enabled = true
        trusted_hash = "sha256:aaaa"
        \(CodexUserConfig.endMarker)

        """
    }

    /// A home with a `config.toml` holding `contents`, for `body`.
    private func withConfig(
        _ contents: Data,
        _ body: (_ home: URL, _ config: URL) throws -> Void
    ) throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            try contents.write(to: config)
            try body(home, config)
        }
    }

    @Test("executes the signed approval helper directly")
    func approvalHelperCommand_doesNotInvokeShellAsTheExecutable() {
        let command = CodexHookInstaller.executableCommand(
            for: URL(fileURLWithPath: "/Applications/Weir Dev.app/Contents/MacOS/AgentIntegrationHookHelper")
        )

        #expect(command == "'/Applications/Weir Dev.app/Contents/MacOS/AgentIntegrationHookHelper'")
        #expect(!command.contains("/bin/sh"))
    }

    /// The installer is the one component that edits a file outside our
    /// own container, and `WeirApp` cleans it during bootstrap —
    /// which the Xcode test host also runs. Without this the suite
    /// rewrites the developer's own `~/.codex/config.toml` on every run.
    @Test("keeps the default home off the user's own while under test")
    func defaultUserCodexHome_underTestHost_isNotTheRealHome() {
        let real = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
        #expect(CodexHookInstaller().userCodexHome != real)
    }

    @Test("takes an earlier build's tables out of an injected home")
    func removeLegacyTrust_injectedHome_removesTheBlock() throws {
        try withConfig(Data(withLegacyBlock.utf8)) { home, config in
            let installer = CodexHookInstaller(userCodexHome: home)
            #expect(installer.removeLegacyTrust(writesUserFiles: true) == .removed)
            let written = try String(contentsOf: config, encoding: .utf8)
            #expect(written == theirs)
            #expect(installer.removeLegacyTrust(writesUserFiles: true) == .unchanged)
        }
    }

    @Test("does not create a config that is not there")
    func removeLegacyTrust_noConfig_writesNothing() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            #expect(CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true) == .unchanged)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("config.toml").path))
        }
    }

    /// Read as empty, a config we cannot decode would be replaced by an
    /// empty file, and every setting the person had would go with it.
    @Test("leaves a config that is not UTF-8 alone and fails")
    func removeLegacyTrust_configNotUTF8_leavesItAlone() throws {
        // A Latin-1 comment: `# café`.
        let latin1 = Data(withLegacyBlock.utf8) + Data("# caf".utf8) + Data([0xE9, 0x0A])
        try withConfig(latin1) { home, config in
            let outcome = CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true)
            #expect(outcome == .failed(.notUTF8))
            let written = try Data(contentsOf: config)
            #expect(written == latin1)
        }
    }

    @Test("leaves a config it cannot read alone and fails")
    func removeLegacyTrust_configUnreadable_leavesItAlone() throws {
        let original = Data(withLegacyBlock.utf8)
        try withConfig(original) { home, config in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
            let outcome = CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true)
            // Readable again before anything else, so the directory can be
            // removed whatever the expectations find.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            #expect(outcome == .failed(.unreadable))
            let written = try Data(contentsOf: config)
            #expect(written == original)
        }
    }

    @Test("keeps a byte order mark the config began with")
    func removeLegacyTrust_configWithByteOrderMark_keepsIt() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data(withLegacyBlock.utf8)
        try withConfig(original) { home, config in
            #expect(CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true) == .removed)
            let written = try Data(contentsOf: config)
            #expect(written == Data([0xEF, 0xBB, 0xBF]) + Data(theirs.utf8))
        }
    }

    /// People keep `config.toml` in a dotfiles checkout and link it in. An
    /// atomic write to the link's path would replace the link with a
    /// regular file, and the checkout would keep the tables.
    @Test("writes through a symbolic link and keeps the link")
    func removeLegacyTrust_symlinkedConfig_writesTheTargetAndKeepsTheLink() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            let dotfiles = dir.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let target = dotfiles.appendingPathComponent("config.toml")
            try withLegacyBlock.write(to: target, atomically: true, encoding: .utf8)
            let link = home.appendingPathComponent("config.toml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/config.toml")

            #expect(CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true) == .removed)

            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/config.toml")
            #expect(try String(contentsOf: target, encoding: .utf8) == theirs)
        }
    }

    @Test("leaves a link to nothing alone and fails")
    func removeLegacyTrust_danglingSymlink_leavesItAlone() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let link = home.appendingPathComponent("config.toml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/config.toml")

            #expect(CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true) == .failed(.danglingLink))

            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/config.toml")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("dotfiles").path))
        }
    }

    /// A config Codex cannot parse keeps Codex from starting, so an edit
    /// that would produce one is not written. Removing lines of ours cannot
    /// break a config that loads, but a config that already does not load
    /// is not ours to rewrite: here the person defines `[tui]` twice.
    @Test("leaves the config alone when the result would not load")
    func removeLegacyTrust_invalidResult_leavesTheConfigAlone() throws {
        let original = Data(("[tui]\ntheme = \"dark\"\n\n[tui]\ntheme = \"light\"\n\n" + withLegacyBlock).utf8)
        try withConfig(original) { home, config in
            let outcome = CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: true)
            #expect(outcome == .failed(.invalidResult))
            let written = try Data(contentsOf: config)
            #expect(written == original)
        }
    }

    @Test("leaves the config alone in a run that may not write")
    func removeLegacyTrust_inDemoMode_leavesTheConfigAlone() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            let original = withLegacyBlock
            try original.write(to: config, atomically: true, encoding: .utf8)

            #expect(CodexHookInstaller(userCodexHome: home).removeLegacyTrust(writesUserFiles: false) == .skipped)

            #expect(try String(contentsOf: config, encoding: .utf8) == original)
        }
    }

    @Test("routes PermissionRequest through the helper, with its trust in the same flags")
    func approvalRouting_carriesItsTrust() throws {
        try withTempDir { dir in
            let lifecycle = dir.appendingPathComponent("weir-hook")
            let helper = dir.appendingPathComponent("AgentIntegrationHookHelper")
            #expect(FileManager.default.createFile(atPath: lifecycle.path, contents: Data()))
            #expect(FileManager.default.createFile(
                atPath: helper.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o700]
            ))
            let installer = CodexHookInstaller(
                userCodexHome: dir.appendingPathComponent(".codex", isDirectory: true),
                hookScriptURL: lifecycle,
                worktreeHookScriptURL: nil,
                approvalHelperURL: helper
            )

            let arguments = installer.environment(writesRecords: true)["WEIR_CODEX_HOOK_ARGS"] ?? ""
            #expect(arguments.contains("permission-request codex"))
            let expectedHash = CodexTrustHash.compute(
                eventLabel: "permission_request",
                command: CodexHookInstaller.executableCommand(for: helper)
                    + " permission-request codex",
                timeoutSec: 600
            )
            #expect(arguments.contains(expectedHash))
        }
    }
}
