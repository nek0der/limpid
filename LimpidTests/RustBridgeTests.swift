// RustBridgeTests.swift
// LimpidTests — Verifies that the application links and calls the Rust bridge.

import Testing
@testable import Limpid

struct RustBridgeTests {
    @Test func abiVersion_matchesSwiftContract() {
        #expect(LimpidRustRuntime.abiVersion == 1)
    }
}
