// AgentKind.swift
// Limpid — identifier for which AI agent is driving a pane. Currently
// `.claude` and `.codex` are the only producers of lifecycle badges;
// future agents (Gemini, etc.) extend this enum. Lives next to
// `AgentState` because anywhere we surface "which agent finished /
// is waiting", we need both pieces together.

import Foundation

enum AgentKind: String, Codable, CaseIterable, Equatable {
    case claude
    case codex
}
