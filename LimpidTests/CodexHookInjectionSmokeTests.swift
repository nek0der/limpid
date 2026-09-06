// CodexHookInjectionSmokeTests.swift
// Limpid — hands the generated flags and trust block to a real `codex` and
// asks it what it discovered. The unit tests pin that our hashes cover our
// commands; only Codex can say whether it agrees, and the difference shows
// up as a "Hooks need review" prompt in front of the user.
//
// Driven through `codex app-server`'s `hooks/list`, which resolves and
// reports hooks without starting a session, so this costs no model turn.

import Foundation
import Testing
@testable import Limpid

/// Outside the suite because a `@Suite` trait cannot reference a static on
/// the type it is decorating.
private let installedCodex: String? = {
    for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        where FileManager.default.isExecutableFile(atPath: candidate)
    {
        return candidate
    }
    return nil
}()

@Suite(
    "Codex hook injection smoke",
    .tags(.smoke),
    .disabled(if: installedCodex == nil, "no codex on PATH")
)
struct CodexHookInjectionSmokeTests {
    private struct DiscoveredHook: Decodable {
        let eventName: String
        let source: String
        let trustStatus: String
    }

    /// Start an app-server against `home`, ask for the hooks it resolves
    /// for `cwd`, and return them.
    private func discoveredHooks(
        home: URL,
        cwd: URL,
        extraArguments: [String]
    ) throws -> [DiscoveredHook] {
        let process = Process()
        process.executableURL = try URL(fileURLWithPath: #require(installedCodex))
        // Flags first, subcommand after: the layout `codex-shim/codex`
        // produces. Verifying the other order would leave the one the
        // user actually gets unproven.
        process.arguments = extraArguments + ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        process.environment = environment

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        defer { process.terminate() }

        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            stdin.fileHandleForWriting.write(data)
        }
        try send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "limpid-tests", "version": "0"]]
        ])
        try send([
            "jsonrpc": "2.0", "id": 2, "method": "hooks/list",
            "params": ["cwds": [cwd.path]]
        ])

        // Read until the hooks/list reply; the server stays up afterwards.
        var buffer = Data()
        let handle = stdout.fileHandleForReading
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            buffer.append(handle.availableData)
            guard let text = String(data: buffer, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data)
                      as? [String: Any],
                      message["id"] as? Int == 2,
                      let result = message["result"] as? [String: Any],
                      let entries = result["data"] as? [[String: Any]]
                else { continue }
                let hooks = entries.compactMap { $0["hooks"] as? [[String: Any]] }.flatMap(\.self)
                let payload = try JSONSerialization.data(withJSONObject: hooks)
                return try JSONDecoder().decode([DiscoveredHook].self, from: payload)
            }
        }
        return []
    }

    @Test("Codex trusts every hook the flags supply")
    func generatedFlagsAndTrustBlock_areAcceptedByCodex() throws {
        try withTempDir { dir in
            let home = dir.appendingPathComponent("codex-home", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

            let lifecycle = "/bin/echo lifecycle"
            let block = CodexHookInjection.trustBlock(
                lifecycleCommand: lifecycle, worktreeCommand: nil
            )
            try CodexUserConfig.applying(block: block, to: "")
                .write(
                    to: home.appendingPathComponent("config.toml"),
                    atomically: true,
                    encoding: .utf8
                )

            let hooks = try discoveredHooks(
                home: home,
                cwd: dir,
                extraArguments: CodexHookInjection.arguments(
                    lifecycleCommand: lifecycle, worktreeCommand: nil
                )
            )
            let ours = hooks.filter { $0.source == "sessionFlags" }
            #expect(ours.count == CodexHookInstaller.subscribedEvents.count)
            #expect(
                ours.allSatisfy { $0.trustStatus == "trusted" },
                "untrusted: \(ours.filter { $0.trustStatus != "trusted" }.map(\.eventName))"
            )
        }
    }
}
