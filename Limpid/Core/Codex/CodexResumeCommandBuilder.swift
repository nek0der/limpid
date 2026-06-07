// CodexResumeCommandBuilder.swift
// Limpid — backward-compat redirect to the generic
// `AgentResumeCommandBuilder<CodexAgent>`. See
// `ClaudeResumeCommandBuilder.swift` for the sub-phase 2.2c
// rationale. The Codex priority gate (skip when a Claude session is
// live on the same pane) lives on `CodexAgent.shouldResume`.

import Foundation

typealias CodexResumeCommandBuilder = AgentResumeCommandBuilder<CodexAgent>
