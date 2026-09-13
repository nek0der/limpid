// RustBridgeTests.swift
// LimpidTests — Verifies that the application links and calls the Rust bridge.

import Testing
@testable import Limpid

struct RustBridgeTests {
    @Test func abiVersion_matchesSwiftContract() {
        #expect(LimpidRustRuntime.abiVersion == 2)
    }

    @Test("Rust selects and trims the provider session title")
    func titleResolver_prefersProviderSessionTitle() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: "  Formal title  ",
            providerGeneratedTitle: "Generated title",
            firstPrompt: "Opening prompt"
        )

        #expect(title == "Formal title")
    }

    @Test("Rust falls back through blank and absent candidates")
    func titleResolver_usesGeneratedFallback() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: " \n ",
            providerGeneratedTitle: "Generated title",
            firstPrompt: nil
        )

        #expect(title == "Generated title")
    }

    @Test("Rust sanitizes unsafe title scalars before returning to Swift")
    func titleResolver_sanitizesForSingleLineDisplay() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: "  Safe\u{202E}\n\t title\u{200B}  ",
            providerGeneratedTitle: nil,
            firstPrompt: nil
        )

        #expect(title == "Safe title")
    }

    @Test("Rust ignores an oversized fallback after selecting a formal title")
    func titleResolver_doesNotValidateUnusedFallback() {
        let title = LimpidRustTitleResolver.resolve(
            providerSessionTitle: "Formal title",
            providerGeneratedTitle: nil,
            firstPrompt: String(repeating: "x", count: 4097)
        )

        #expect(title == "Formal title")
    }

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
