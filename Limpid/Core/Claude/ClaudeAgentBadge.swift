// ClaudeAgentBadge.swift
// Limpid — backward-compat redirect to the unified `AgentBadge`
// (`Limpid/Core/Agent/AgentKind.swift`). The Claude / Codex badge
// structs were structurally identical apart from Codex's
// `firstPrompt` field; sub-phase 2.2a collapsed them into one type.
// Existing references to `ClaudeAgentBadge` still resolve via the
// typealias declared in `AgentKind.swift`.
