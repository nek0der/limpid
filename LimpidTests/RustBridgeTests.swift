// RustBridgeTests.swift
// Limpid — verifies that the application links and calls the Rust bridge.
//
// The title rules are the Rust crate's and are tested there; these check
// only what the Swift wrapper adds: the strings crossing the ABI each way,
// and the output buffer it hands Rust being the protocol's limit.

import Testing
@testable import Limpid

struct RustBridgeTests {
    @Test func abiVersion_matchesSwiftContract() {
        #expect(LimpidRustRuntime.abiVersion == 4)
    }

    /// Every candidate goes across, and the chosen title comes back as
    /// UTF-8 with what Rust took out of it gone.
    @Test("a title makes the round trip through the Rust bridge")
    func titleResolver_roundTripsThroughTheABI() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: " \n ",
            providerGeneratedTitle: "  Safe\u{202E}\n\t título\u{200B}  ",
            firstPrompt: "Opening prompt"
        )

        #expect(title == "Safe título")
    }

    /// A fallback past the limit is cut to exactly what the output buffer
    /// holds, not refused for overflowing it.
    @Test("Rust truncates a long opening prompt into a bounded fallback")
    func titleResolver_truncatesLongPromptFallback() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: nil,
            providerGeneratedTitle: nil,
            firstPrompt: String(repeating: "x", count: 4097)
        )

        #expect(title?.utf8.count == 4096)
    }
}
