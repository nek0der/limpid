// ClaudeResumeCommandBuilder.swift
// Weir — backward-compat redirect to the generic
// `AgentResumeCommandBuilder<ClaudeAgent>`. The Claude and Codex builders
// share one implementation over the `AgentSpec` protocol; the per-flavor
// command shape (`claude --resume <id>`) lives on
// `ClaudeAgent.resumeCommand`.

import Foundation

typealias ClaudeResumeCommandBuilder = AgentResumeCommandBuilder<ClaudeAgent>
