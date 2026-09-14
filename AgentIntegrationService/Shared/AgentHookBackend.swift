// AgentHookBackend.swift
// Limpid — which receiver the provider hooks exec into.
//
// The bundled `limpid-hook` scripts are thin wrappers that read this variable
// and exec either the Rust hook runtime inside the signed Hook Helper or the
// previous shell receiver (`limpid-hook.legacy`). The value is fixed per pane
// when its shell starts and travels into tmux with the other pane variables,
// so one run is written by one backend even across an app update. The shell
// backend stays for one release as the rollback path.

import Foundation

enum AgentHookBackend: String {
    case rust
    case shell

    /// The variable the wrappers read.
    static let environmentKey = "LIMPID_AGENT_HOOK_BACKEND"

    /// What every new pane gets until the Rust backend becomes the default.
    static let current: AgentHookBackend = .shell

    /// The environment entry for a pane.
    static var environment: [String: String] {
        [environmentKey: current.rawValue]
    }
}
