// ProjectSwitchRecorder.swift
// Weir — a session's windows switching projects in place, recorded rather than handed to an app layer.

import Foundation
@testable import Weir

/// Has a session switch windows between projects in place, as the
/// supervision window's does (`WorkspaceSession.projectSwitching`), and
/// records what the app layer is told: the windows brought forward, and
/// each switch with its reason. For suites that test the session's side
/// without a registry; a suite that tests the windows connects a registry
/// (`WindowRegistry.connectProjectSwitching(of:)`).
@MainActor
final class ProjectSwitchRecorder {
    /// One switch the app layer was told of, before it happened.
    struct Switch: Equatable {
        let window: WindowID
        let from: UUID?
        let to: UUID?
        let reason: ProjectSwitchReason
    }

    private(set) var raised: [WindowID] = []
    private(set) var switches: [Switch] = []
    /// The windows told they had switched, in order.
    private(set) var arrived: [WindowID] = []

    /// Whether the session switched no window and brought none forward.
    var isUntouched: Bool {
        raised.isEmpty && switches.isEmpty && arrived.isEmpty
    }

    /// Connects a recorder to `session`, which from then on switches its
    /// windows in place.
    @discardableResult
    static func connect(to session: WorkspaceSession) -> ProjectSwitchRecorder {
        let recorder = ProjectSwitchRecorder()
        session.projectSwitching = ProjectSwitchHandlers(
            onRaiseWindow: { recorder.raised.append($0) },
            willSwitchProject: { window, from, to, reason in
                recorder.switches.append(Switch(window: window, from: from, to: to, reason: reason))
            },
            didSwitchProject: { window, _ in recorder.arrived.append(window) }
        )
        return recorder
    }
}
