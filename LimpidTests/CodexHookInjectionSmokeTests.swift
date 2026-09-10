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

private struct InstalledCodex {
    let executable: String
    let searchPath: String
}

/// Ask the interactive login shell for the environment a Limpid pane gets.
/// Xcode replaces PATH inside its test host, so reading that value directly
/// can select a stale fallback that the user's shell never launches.
private func loginShellSearchPath(environment: [String: String]) -> String? {
    let fallbackShell = "/bin/zsh"
    let requestedShell = environment["SHELL"] ?? fallbackShell
    let shell = FileManager.default.isExecutableFile(atPath: requestedShell)
        ? requestedShell
        : fallbackShell
    let marker = "__LIMPID_PATH__"
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-lic", "printf '\\n\(marker)%s\\n' \"$PATH\""]
    process.environment = environment
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8),
          let line = text.split(separator: "\n").last(where: { $0.hasPrefix(marker) })
    else { return nil }
    return String(line.dropFirst(marker.count))
}

private func firstCodex(in searchPath: String) -> String? {
    for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
        let path = directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)
        let candidate = URL(fileURLWithPath: path).appendingPathComponent("codex").path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Outside the suite because a `@Suite` trait cannot reference a static on
/// the type it is decorating.
private let installedCodex: InstalledCodex? = {
    let environment = ProcessInfo.processInfo.environment
    let processPath = environment["PATH"] ?? ""
    if let override = environment["LIMPID_REAL_CODEX"],
       FileManager.default.isExecutableFile(atPath: override)
    {
        return InstalledCodex(executable: override, searchPath: processPath)
    }
    if let loginPath = loginShellSearchPath(environment: environment),
       let executable = firstCodex(in: loginPath)
    {
        return InstalledCodex(executable: executable, searchPath: loginPath)
    }
    if let executable = firstCodex(in: processPath) {
        return InstalledCodex(executable: executable, searchPath: processPath)
    }
    for fallback in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        where FileManager.default.isExecutableFile(atPath: fallback)
    {
        return InstalledCodex(executable: fallback, searchPath: processPath)
    }
    return nil
}()

@Suite(
    "Codex hook injection smoke",
    .tags(.smoke),
    .disabled(if: installedCodex == nil, "no Codex executable found")
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
        let installedCodex = try #require(installedCodex)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: installedCodex.executable)
        // Flags first, subcommand after: the layout `codex-shim/codex`
        // produces. Verifying the other order would leave the one the
        // user actually gets unproven.
        process.arguments = extraArguments + ["app-server"]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        environment["PATH"] = installedCodex.searchPath
        // A test launched from a Limpid pane inherits the flags that pane's
        // shim injects. The explicit arguments above are the subject of this
        // test, so allowing the inherited copy through a selected shim would
        // count every hook twice and test a command the user never receives.
        environment.removeValue(forKey: "LIMPID_CODEX_HOOK_ARGS")
        environment.removeValue(forKey: "LIMPID_AGENT_TMUX")
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
            let expected = Set(CodexHookInstaller.subscribedEvents.map {
                $0.jsonKey.prefix(1).lowercased() + $0.jsonKey.dropFirst()
            })
            let actual = Set(ours.map(\.eventName))
            let missing = expected.subtracting(actual).sorted()
            let unexpected = actual.subtracting(expected).sorted()
            #expect(
                actual == expected,
                "codex: \(installedCodex?.executable ?? "missing"); missing: \(missing); unexpected: \(unexpected)"
            )
            #expect(
                ours.allSatisfy { $0.trustStatus == "trusted" },
                "untrusted: \(ours.filter { $0.trustStatus != "trusted" }.map(\.eventName))"
            )
        }
    }
}
