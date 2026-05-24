// ObservationHelpers.swift
// Limpid — small wrappers around `withObservationTracking` that make
// the "track once, re-arm after each fire" idiom a one-liner.

import Foundation
import Observation

/// Subscribe to mutations of the properties read inside `track`. The
/// first mutation invokes `onChange` and the tracker is re-armed for the
/// next round. Use this whenever a long-running coordinator needs to
/// react to repeated changes on an `@Observable` source.
///
/// ```swift
/// observeRepeatedly {
///     _ = session.title
/// } onChange: {
///     self.window.title = session.title
/// }
/// ```
@MainActor
func observeRepeatedly(
    _ track: @escaping @MainActor () -> Void,
    onChange: @escaping @MainActor () -> Void
) {
    withObservationTracking(track) {
        Task { @MainActor in
            onChange()
            observeRepeatedly(track, onChange: onChange)
        }
    }
}
