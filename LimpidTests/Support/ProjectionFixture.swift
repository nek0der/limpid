// ProjectionFixture.swift
// Limpid — builds a projection adapter over a scratch provider directory.
//
// Suites that need one provider's rules exercised construct this: it wires
// the provider's directories into an adapter with an injectable liveness
// answer.

import Foundation
@testable import Limpid

@MainActor
enum ProjectionFixture {
    /// An adapter reading one provider's records out of `state` and its resume
    /// hints out of `sessions`, with liveness answered by `processStatus`.
    static func adapter(
        provider: String = "codex",
        state: URL,
        sessions: URL,
        resumeIntents: AgentResumeIntentStore? = nil,
        processStatus: @escaping (String?) -> AgentProcessStatus = AgentProcessStatus.inspect
    ) -> AgentProjectionAdapter {
        AgentProjectionAdapter(
            directories: [provider: AgentDirectories(state: state, sessions: sessions, cwdEvents: nil)],
            descriptors: AgentProviderRegistry.descriptors.filter { $0.key == provider },
            resumeIntents: resumeIntents
                ?? AgentResumeIntentStore(
                    directory: state.appendingPathComponent("resume-intents", isDirectory: true)
                ),
            processStatus: processStatus
        )
    }
}
