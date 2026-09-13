// LimpidRustBridge.swift
// Limpid — Typed Swift access to the Rust core ABI boundary.

import LimpidRustBridge

enum LimpidRustRuntime {
    static var abiVersion: UInt32 {
        limpid_rust_abi_version()
    }
}
