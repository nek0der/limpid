// IsolatedProcessEnvironment.swift
// Limpid — builds the environment for child processes a test spawns from
// scratch, keeping only the toolchain variables the child must inherit.

import Foundation

enum IsolatedProcessEnvironment {
    /// Variables the toolchain sets on the test host that a child process
    /// must inherit even though the suites otherwise start from an empty
    /// environment.
    ///
    /// The suites replace the environment so a stray `LIMPID_*` or `HOME`
    /// from the developer's shell cannot reach the process under test.
    /// Xcode's coverage runtime is not user state, though: with
    /// `-enableCodeCoverage YES` every bundled executable is instrumented,
    /// and at exit it writes its profile to the path in `LLVM_PROFILE_FILE`.
    /// Without the variable the runtime falls back to `default.profraw` in
    /// the working directory, which is read-only under `xcodebuild test`,
    /// and the resulting error on stderr fails the suites that assert the
    /// child stays quiet. Xcode's value contains a `%p` placeholder, so
    /// every process the tests spawn writes its own file next to the
    /// host's and the report merges them.
    private static let inheritedKeys = ["LLVM_PROFILE_FILE"]

    /// An environment that contains only `overrides` plus the toolchain
    /// variables from `inheritedKeys`, with `overrides` taking precedence.
    static func make(_ overrides: [String: String]) -> [String: String] {
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
