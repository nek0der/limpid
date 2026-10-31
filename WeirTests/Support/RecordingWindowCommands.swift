// RecordingWindowCommands.swift
// Weir — a `WindowCommandPerforming` that records each command and the window it was asked of.

import Foundation
@testable import Weir
@testable import WeirDomain

/// Takes every command it is handed and remembers it with its window, for
/// suites about what is asked of which window rather than what the window's
/// views then do.
@MainActor
final class RecordingWindowCommands: WindowCommandPerforming {
    private(set) var performed: [(command: WindowCommand, window: WindowID)] = []

    @discardableResult
    func perform(_ command: WindowCommand, in window: WindowID) -> Bool {
        performed.append((command, window))
        return true
    }

    /// The commands asked of `window`, in order.
    func commands(in window: WindowID) -> [WindowCommand] {
        performed.filter { $0.window == window }.map(\.command)
    }
}
