// PrimaryKeyHintTests.swift
// Limpid — the "⌘⏎" beside the decision bar's primary button goes after three uses of the key.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Primary key hint")
struct PrimaryKeyHintTests {
    @Test func theHint_goesAfterThreeUsesOfTheKey_andStaysGone() throws {
        let defaults = try #require(InMemoryDefaults())
        let hint = PrimaryKeyHint(defaults: defaults)
        for _ in 1..<PrimaryKeyHint.usesBeforeHidden {
            hint.noteKeyUse()
        }
        #expect(hint.isShown)

        hint.noteKeyUse()

        #expect(!hint.isShown)
        #expect(!PrimaryKeyHint(defaults: defaults).isShown, "counted across launches")
    }

    @Test func aRunThatMayNotWrite_countsInMemoryOnly() {
        let hint = PrimaryKeyHint(defaults: nil)
        for _ in 0..<PrimaryKeyHint.usesBeforeHidden {
            hint.noteKeyUse()
        }

        #expect(!hint.isShown)
        #expect(PrimaryKeyHint(defaults: nil).isShown)
    }
}
