// CodexResumeCommandBuilder.swift
// Limpid — backward-compat redirect to the generic
// `AgentResumeCommandBuilder<CodexAgent>`. Whether Codex yields to a Claude
// session on the same pane is decided by the projection and read from
// `Tab.agentResumeCandidates`.

import Foundation

typealias CodexResumeCommandBuilder = AgentResumeCommandBuilder<CodexAgent>
