// GhosttyAvailability.swift
// Weir — whether libghostty is loaded, for the tests that need a real terminal surface.

import Foundation
@testable import Weir

enum GhosttyAvailability {
    /// Whether the app host loaded libghostty. A test bundle run without
    /// it has no terminal to make, which is a missing precondition rather
    /// than a failure, so the FFI tests are enabled on this.
    nonisolated static func isAvailable() async -> Bool {
        await MainActor.run { GhosttyApp.placeholder.target != nil }
    }
}
