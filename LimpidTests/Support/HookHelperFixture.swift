// HookHelperFixture.swift
// Limpid — locates the bundled Hook Helper beside the test host and builds the
// isolated environment the hook suites hand to the processes that exec it.

import Foundation

enum HookHelperFixture {
    /// The `AgentIntegrationHookHelper` embedded beside the test host's
    /// executable; `nil` when the test bundle runs without its app host, which
    /// is a missing precondition rather than a failure.
    static let helperURL: URL? = {
        guard let executable = Bundle.main.executableURL else { return nil }
        let helper = executable.deletingLastPathComponent().appendingPathComponent("AgentIntegrationHookHelper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }()

    /// Variables the toolchain sets on the test host that a child process
    /// must inherit even though the suites otherwise start from an empty
    /// environment.
    ///
    /// The hook suites replace the environment so a stray `LIMPID_*` or
    /// `HOME` from the developer's shell cannot reach the helper. Xcode's
    /// coverage runtime is not user state, though: with `-enableCodeCoverage
    /// YES` the helper is instrumented, and at exit it writes its profile to
    /// the path in `LLVM_PROFILE_FILE`. Without the variable the runtime
    /// falls back to `default.profraw` in the working directory, which is
    /// read-only under `xcodebuild test`, and the resulting error on stderr
    /// fails the suites that assert the helper stays quiet. Xcode's value
    /// contains a `%p` placeholder, so every process the tests spawn writes
    /// its own file next to the host's and the report merges them.
    private static let inheritedKeys = ["LLVM_PROFILE_FILE"]

    /// An environment that contains only `overrides` plus the toolchain
    /// variables from `inheritedKeys`, with `overrides` taking precedence.
    static func isolatedEnvironment(_ overrides: [String: String]) -> [String: String] {
        let host = ProcessInfo.processInfo.environment
        var environment = [String: String]()
        for key in inheritedKeys {
            if let value = host[key] {
                environment[key] = value
            }
        }
        environment.merge(overrides) { _, override in override }
        return environment
    }
}
