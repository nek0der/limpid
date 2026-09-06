// CodexShimScriptTests.swift
// Limpid — drives `codex-shim/codex` with `LIMPID_REAL_CODEX` pointed at a
// stub that records what it was handed. Codex had no shim at all, so this
// pins what the new one owes its caller: the user's arguments arrive
// untouched behind our own, and the pid the receiver watches is the
// agent's own.

import Foundation
import Testing

@Suite("Codex shim", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct CodexShimScriptTests {
    private struct Handoff {
        var argv: [String]
        var codexPID: String?
        /// The stub's own pid, which `exec` makes the agent's pid too.
        var ownPID: String?
    }

    private func runShim(
        _ args: [String],
        hookArgs: String? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> Handoff {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let shim = root.appendingPathComponent("Limpid/Resources/codex-shim/codex")
            let stub = dir.appendingPathComponent("fake-codex")
            let argvFile = dir.appendingPathComponent("argv")
            let envFile = dir.appendingPathComponent("env")
            // NUL-separated so a multi-line argument stays one argument.
            try """
            #!/bin/sh
            : > "\(argvFile.path)"
            for a in "$@"; do printf '%s\\000' "$a" >> "\(argvFile.path)"; done
            printf '%s\\n%s\\n' "${LIMPID_CODEX_PID:-}" "$$" > "\(envFile.path)"
            exit 0
            """.write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: stub.path
            )

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [shim.path] + args
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "TMPDIR": dir.path,
                "LIMPID_REAL_CODEX": stub.path
            ]
            if let hookArgs {
                process.environment?["LIMPID_CODEX_HOOK_ARGS"] = hookArgs
            }
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, sourceLocation: sourceLocation)

            let argv = ((try? String(contentsOf: argvFile, encoding: .utf8)) ?? "")
                .split(separator: "\0").map(String.init)
            let lines = ((try? String(contentsOf: envFile, encoding: .utf8)) ?? "")
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            return Handoff(
                argv: argv,
                codexPID: lines.first.flatMap { $0.isEmpty ? nil : $0 },
                ownPID: lines.count > 1 ? lines[1] : nil
            )
        }
    }

    @Test("hands the user's arguments through unchanged")
    func passesArgumentsThrough() throws {
        let handoff = try runShim(["exec", "--skip-git-repo-check", "hello world"])
        #expect(handoff.argv.suffix(3) == ["exec", "--skip-git-repo-check", "hello world"])
    }

    /// The flags arrive through the environment rather than being built
    /// in shell: the same Swift that writes the trust block has to
    /// produce them, or the hashes stop covering what is actually passed.
    @Test("splices the hook flags in ahead of the user's arguments")
    func splicesHookArgumentsBeforeUserArguments() throws {
        let handoff = try runShim(
            ["resume"],
            hookArgs: "-c\nhooks.Stop=[{hooks=[]}]\n-c\ntui.terminal_title=[]"
        )
        #expect(handoff.argv == [
            "-c", "hooks.Stop=[{hooks=[]}]", "-c", "tui.terminal_title=[]", "resume"
        ])
    }

    @Test("leaves the command line alone when there are no hook flags")
    func noHookArguments_passesThrough() throws {
        let handoff = try runShim(["resume"])
        #expect(handoff.argv == ["resume"])
    }

    /// `exec` gives the shim's shell pid to the agent, so exporting it
    /// before the handover is what lets the receiver skip walking the
    /// process tree to guess which ancestor is Codex.
    @Test("exports its own pid as the agent's")
    func exportsItsOwnPidAsTheAgents() throws {
        let handoff = try runShim([])
        #expect(handoff.codexPID != nil)
        #expect(handoff.codexPID == handoff.ownPID)
    }
}
