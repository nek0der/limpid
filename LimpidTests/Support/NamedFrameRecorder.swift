// NamedFrameRecorder.swift
// Limpid — where each recorded view was last laid out, in a named coordinate space, for the layout suites.

import SwiftUI

/// Where each recorded view was last laid out, in the space named `space`,
/// which the test lays its root out in.
@MainActor
final class NamedFrameRecorder {
    nonisolated let space: String
    var frames: [String: CGRect] = [:]

    nonisolated init(space: String) {
        self.space = space
    }
}

extension View {
    /// Records this view's frame in `recorder`'s space, under `name`.
    func recordFrame(in recorder: NamedFrameRecorder, as name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(recorder.space)) } action: {
            recorder.frames[name] = $0
        }
    }
}
