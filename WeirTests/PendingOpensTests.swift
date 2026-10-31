// PendingOpensTests.swift
// Weir — what is handed to Weir before launching finishes waits for the restored windows, and nothing waits after.

import Foundation
import Testing
@testable import Weir

struct PendingOpensTests {
    private static let first = URL(fileURLWithPath: "/tmp/first", isDirectory: true)
    private static let second = URL(fileURLWithPath: "/tmp/second", isDirectory: true)

    @Test func beforeLaunchFinishes_everythingIsHeld_thenHandedOverOnceInOrder() {
        var opens = PendingOpens()
        #expect(opens.receive([Self.first]).isEmpty)
        #expect(opens.receive([Self.second]).isEmpty)

        #expect(opens.finishLaunching() == [Self.first, Self.second])
        #expect(opens.hasFinishedLaunching)
        // Handed over once: a second finish has nothing left.
        #expect(opens.finishLaunching().isEmpty)
    }

    @Test func afterLaunchFinishes_whatArrivesOpensAtOnce() {
        var opens = PendingOpens()
        #expect(opens.finishLaunching().isEmpty)

        #expect(opens.receive([Self.first, Self.second]) == [Self.first, Self.second])
        #expect(opens.finishLaunching().isEmpty)
    }
}
