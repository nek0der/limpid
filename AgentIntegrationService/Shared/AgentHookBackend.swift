// AgentHookBackend.swift
// Limpid — which receiver the provider hooks exec into.
//
// The bundled `limpid-hook` scripts are thin wrappers that read this variable
// and exec either the Rust hook runtime inside the signed Hook Helper or the
// previous shell receiver (`limpid-hook.legacy`). The value is fixed per pane
// when its shell starts and travels into tmux with the other pane variables.
// Both backends read and write the same record files, so a pane that changes
// backend mid-run (the wrapper falls back to the shell receiver when the
// helper is missing) keeps its record. The shell backend stays for one
// release as the rollback path. This file is shared with the Hook Helper so
// the app and the helper agree on the key and the rollback value.

import Foundation

enum AgentHookBackend: String {
    case rust
    case shell

    /// The variable the wrappers read.
    static let environmentKey = "LIMPID_AGENT_HOOK_BACKEND"

    /// What every new pane gets. The Rust runtime is the default; `shell`
    /// is the rollback path for one release and is then removed with the
    /// legacy scripts.
    static let current: AgentHookBackend = .rust

    /// The environment entry for a pane.
    static var environment: [String: String] {
        [environmentKey: current.rawValue]
    }
}
