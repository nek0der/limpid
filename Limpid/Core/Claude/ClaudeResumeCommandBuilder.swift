// ClaudeResumeCommandBuilder.swift
// Limpid — backward-compat redirect to the generic
// `AgentResumeCommandBuilder<ClaudeAgent>`. Sub-phase 2.2c collapsed
// the two parallel builder enums onto the `AgentSpec` protocol. The
// per-flavor command shape (`claude --resume <id>`) lives on
// `ClaudeAgent.resumeCommand`.

import Foundation

typealias ClaudeResumeCommandBuilder = AgentResumeCommandBuilder<ClaudeAgent>
