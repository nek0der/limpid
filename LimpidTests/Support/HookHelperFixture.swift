// HookHelperFixture.swift
// Limpid — locates the bundled Hook Helper beside the test host.

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
}
