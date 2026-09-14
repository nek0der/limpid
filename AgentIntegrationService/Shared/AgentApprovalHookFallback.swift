// AgentApprovalHookFallback.swift
// Limpid — the one provider-specific path the Hook Helper keeps in Swift.
//
// Request and response translation moved to the Rust provider crates and is
// reached through `RustProviderBridge`. What remains is locating the Codex
// lifecycle receiver beside the helper, which is a bundle-layout fact rather
// than a provider rule.

import Foundation

enum AgentApprovalHookFallback {
    static func codexLifecycleScript(forExecutableURL executableURL: URL) -> URL? {
        let script = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/codex-shim/limpid-hook")
            .standardizedFileURL
        return FileManager.default.isReadableFile(atPath: script.path) ? script : nil
    }
}
