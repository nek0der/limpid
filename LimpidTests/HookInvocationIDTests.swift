// HookInvocationIDTests.swift
// Limpid — the call id each provider's `limpid-hook` wrapper hands the Hook
// Helper. A turn record applies a call once by this id, so a wrapper that
// reused one id for every call would record a single turn per run and drop
// every end after it.

import Foundation
import Testing
@testable import Limpid

@Suite("Hook invocation id", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"), .timeLimit(.minutes(1)))
struct HookInvocationIDTests {
    /// Runs the wrapper twice for `provider` with a stand-in helper that
    /// writes down the id it was handed, and returns the ids in order.
    private func invocationIDs(provider: String, preset: String?) throws -> [String] {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let wrapper = root.appendingPathComponent("Limpid/Resources/\(provider)-shim/limpid-hook")
            let helper = dir.appendingPathComponent("helper")
            let ids = dir.appendingPathComponent("ids")
            try Data("#!/bin/sh\nprintf '%s\\n' \"$LIMPID_HOOK_INVOCATION_ID\" >> \"$LIMPID_TEST_IDS\"\n".utf8)
                .write(to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            for _ in 0..<2 {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [wrapper.path]
                var environment = IsolatedProcessEnvironment.make([
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": dir.path,
                    "LIMPID_HOOK_HELPER": helper.path,
                    "LIMPID_TEST_IDS": ids.path
                ])
                environment["LIMPID_HOOK_INVOCATION_ID"] = preset
                process.environment = environment
                process.standardInput = FileHandle.nullDevice
                try process.run()
                #expect(process.waitUntilExit(within: 10), "the wrapper did not exit within ten seconds")
                #expect(process.terminationStatus == 0)
            }
            return try String(contentsOf: ids, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
        }
    }

    @Test("hands each hook call an id of its own", arguments: ["claude", "codex"])
    func wrapper_mintsAnIDPerCall(provider: String) throws {
        let ids = try invocationIDs(provider: provider, preset: nil)
        #expect(ids.count == 2)
        #expect(ids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(ids).count == 2)
    }

    @Test("does not take an id from the environment", arguments: ["claude", "codex"])
    func wrapper_replacesAnInheritedID(provider: String) throws {
        // One leaked into the agent's environment would otherwise be every
        // call's id.
        let leaked = UUID().uuidString
        let ids = try invocationIDs(provider: provider, preset: leaked)
        #expect(ids.count == 2)
        #expect(!ids.contains(leaked))
        #expect(Set(ids).count == 2)
    }
}
