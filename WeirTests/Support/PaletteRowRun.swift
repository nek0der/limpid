// PaletteRowRun.swift
// Weir — a palette row run as a window's palette commits it, with the stores no window test reads.

import Foundation
@testable import Weir
@testable import WeirDomain

extension CommandPaletteActions {
    /// Runs `action` as committed from `window`'s palette. The ranking it
    /// records goes to a folder of its own, flushed before the folder goes.
    static func runRowForTest(
        _ action: CommandPaletteAction,
        session: WorkspaceSession,
        window: WindowID,
        commands: any WindowCommandPerforming = RecordingWindowCommands(),
        runsInWindow: (CommandPaletteAction) -> PaletteRowHandling = { _ in .notHandled }
    ) throws {
        try withTempDir { dir in
            let frecency = FrecencyStore(directory: dir)
            executeCommandPaletteAction(
                action,
                session: session,
                attention: AttentionState(),
                registry: RecordingSurfaceRegistry(),
                commands: commands,
                frecencyStore: frecency,
                toastCenter: ToastCenter(),
                minPaneSize: 0,
                window: window,
                runsInWindow: runsInWindow
            )
            frecency.flushSynchronously()
        }
    }
}
