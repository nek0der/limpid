// CodexHookInstallerTests.swift
// Limpid — pins what keeps the installer from writing somewhere it should
// not, or over what it could not read: the default home is inert under the
// test runner, an injected home still receives the block, a config it
// cannot read or decode is left alone, and a linked config is written
// through its link.

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

            CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true)

            let written = try String(contentsOf: config, encoding: .utf8)
            #expect(written.hasPrefix("model = \"gpt-5.6-sol\""))
            #expect(written.contains(CodexUserConfig.beginMarker))
            #expect(written.contains("[hooks.state."))
        }
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

    /// Read as empty, a config we cannot decode would be replaced by our
    /// block alone, and every setting the person had would go with it.
    @Test("leaves a config that is not UTF-8 alone and fails")
    func refresh_configNotUTF8_leavesItAlone() throws {
        // A Latin-1 comment: `# café`.
        let latin1 = Data("model = \"gpt-5.6-sol\"\n# caf".utf8) + Data([0xE9, 0x0A])
        try withConfig(latin1) { home, config in
            let outcome = CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true)
            #expect(outcome == .failed(.notUTF8))
            let written = try Data(contentsOf: config)
            #expect(written == latin1)
        }
    }

    @Test("leaves a config it cannot read alone and fails")
    func refresh_configUnreadable_leavesItAlone() throws {
        let original = Data("model = \"gpt-5.6-sol\"\n".utf8)
        try withConfig(original) { home, config in
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)
            let outcome = CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true)
            // Readable again before anything else, so the directory can be
            // removed whatever the expectations find.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            #expect(outcome == .failed(.unreadable))
            let written = try Data(contentsOf: config)
            #expect(written == original)
        }
    }

    @Test("keeps a byte order mark the config began with")
    func refresh_configWithByteOrderMark_keepsIt() throws {
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("model = \"gpt-5.6-sol\"\n".utf8)
        try withConfig(original) { home, config in
            #expect(CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true) == .installed)
            let written = try Data(contentsOf: config)
            #expect(written.starts(with: original))
            #expect(String(bytes: written.dropFirst(3), encoding: .utf8)?.contains(CodexUserConfig.beginMarker) == true)
        }
    }

    /// People keep `config.toml` in a dotfiles checkout and link it in. An
    /// atomic write to the link's path replaced the link with a regular
    /// file, so the checkout never had our block and the next relink lost it.
    @Test("writes through a symbolic link and keeps the link")
    func refresh_symlinkedConfig_writesTheTargetAndKeepsTheLink() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            let dotfiles = dir.appendingPathComponent("dotfiles", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
            let target = dotfiles.appendingPathComponent("config.toml")
            try "model = \"gpt-5.6-sol\"\n".write(to: target, atomically: true, encoding: .utf8)
            let link = home.appendingPathComponent("config.toml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/config.toml")

            #expect(CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true) == .installed)

            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/config.toml")
            let written = try String(contentsOf: target, encoding: .utf8)
            #expect(written.hasPrefix("model = \"gpt-5.6-sol\""))
            #expect(written.contains(CodexUserConfig.beginMarker))
            #expect(CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true) == .unchanged)
        }
    }

    @Test("leaves a link to nothing alone and fails")
    func refresh_danglingSymlink_leavesItAlone() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let link = home.appendingPathComponent("config.toml")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../dotfiles/config.toml")

            #expect(CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: true) == .failed(.danglingLink))

            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "../dotfiles/config.toml")
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("dotfiles").path))
        }
    }

    /// A config Codex cannot parse keeps Codex from starting, so a splice
    /// that would produce one is not written. Here the person holds one of
    /// our tables as an array table, which is not ours to rewrite, and
    /// appending ours beside it would define the name both ways.
    @Test("leaves the config alone when the result would not load")
    func refresh_invalidResult_leavesTheConfigAlone() throws {
        let original = Data("""
        model = "gpt-5.6-sol"

        [[hooks.state."/<session-flags>/config.toml:stop:0:0"]]
        enabled = true

        """.utf8)
        try withConfig(original) { home, config in
            let lifecycle = home.deletingLastPathComponent().appendingPathComponent("limpid-hook")
            #expect(FileManager.default.createFile(atPath: lifecycle.path, contents: Data()))
            let installer = CodexHookInstaller(
                userCodexHome: home,
                hookScriptURL: lifecycle,
                worktreeHookScriptURL: nil,
                approvalHelperURL: nil
            )

            let outcome = installer.refresh(writesUserFiles: true)
            #expect(outcome == .failed(.invalidResult))
            let written = try Data(contentsOf: config)
            #expect(written == original)
        }
    }

    /// An earlier version appended a second copy of one of our tables, and
    /// the two copies set a key that is not ours differently. Repairing the
    /// file would mean choosing one value, so it is left as it was.
    @Test("leaves the config alone when the copies of a table disagree on a key")
    func refresh_duplicateTableWithConflictingKey_leavesTheConfigAlone() throws {
        try withConfig(Data("model = \"gpt-5.6-sol\"\n".utf8)) { home, config in
            let lifecycle = home.deletingLastPathComponent().appendingPathComponent("limpid-hook")
            #expect(FileManager.default.createFile(atPath: lifecycle.path, contents: Data()))
            let installer = CodexHookInstaller(
                userCodexHome: home,
                hookScriptURL: lifecycle,
                worktreeHookScriptURL: nil,
                approvalHelperURL: nil
            )
            #expect(installer.refresh(writesUserFiles: true) == .installed)

            // Duplicate our first table between the markers, and give the
            // two copies different values for a key of their own.
            var lines = try String(contentsOf: config, encoding: .utf8).components(separatedBy: "\n")
            let begin = try #require(lines.firstIndex(of: CodexUserConfig.beginMarker))
            let end = try #require(lines[(begin + 2)...].firstIndex { $0.hasPrefix("[") || $0 == CodexUserConfig.endMarker })
            let copy = Array(lines[(begin + 1)..<end]) + ["note = \"theirs\""]
            lines.insert(contentsOf: ["note = \"mine\""] + copy, at: end)
            let original = Data(lines.joined(separator: "\n").utf8)
            try original.write(to: config)

            #expect(installer.refresh(writesUserFiles: true) == .failed(.invalidResult))
            #expect(try Data(contentsOf: config) == original)
        }
    }

    @Test("leaves the config alone in a run that may not write")
    func refresh_inDemoMode_leavesTheConfigAlone() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let config = home.appendingPathComponent("config.toml")
            let original = "model = \"gpt-5.6-sol\"\n"
            try original.write(to: config, atomically: true, encoding: .utf8)

            CodexHookInstaller(userCodexHome: home).refresh(writesUserFiles: false)

            #expect(try String(contentsOf: config, encoding: .utf8) == original)
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
            installer.refresh(writesUserFiles: true)

            let initial = installer.environment(writesRecords: true)["LIMPID_CODEX_HOOK_ARGS"] ?? ""
            #expect(initial.contains("permission-request codex"))

            installer.refresh(writesUserFiles: true)
            let firstRefresh = installer.environment(writesRecords: true)["LIMPID_CODEX_HOOK_ARGS"] ?? ""
            #expect(firstRefresh == initial)

            installer.refresh(writesUserFiles: true)
            let secondRefresh = installer.environment(writesRecords: true)["LIMPID_CODEX_HOOK_ARGS"] ?? ""
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
