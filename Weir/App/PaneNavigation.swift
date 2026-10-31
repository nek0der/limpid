// PaneNavigation.swift
// Weir — jump-to-pane and flash helpers shared across views

import Foundation
import WeirDomain

@MainActor
func jumpToPane(
    _ paneID: UUID,
    session: WorkspaceSession,
    registry: any SurfaceViewProviding,
    in window: WindowID,
    intent: SelectionIntent
) {
    guard let tab = session.tab(containing: paneID) else { return }
    session.setActiveTab(tab.id, in: window, intent: intent)
    session.update(tab.id) { t in
        t.splitTree.focusedLeafID = paneID
    }
    if let view = registry.view(for: paneID) {
        view.window?.makeFirstResponder(view)
    }
    flashPane(paneID, session: session)
}

/// Per-pane debounce so a rapid second flash on the same pane cancels
/// the first task's "ringing = false" instead of letting it land
/// midway through the second flash and cut it short.
@MainActor
private var flashTasks: [UUID: Task<Void, Never>] = [:]

@MainActor
func flashPane(_ paneID: UUID, session: WorkspaceSession) {
    flashTasks[paneID]?.cancel()
    session.setBell(paneID: paneID, ringing: true)
    flashTasks[paneID] = Task { @MainActor [weak session] in
        try? await Task.sleep(nanoseconds: BellFeatures.paneFlashNanoseconds)
        if Task.isCancelled {
            return
        }
        session?.setBell(paneID: paneID, ringing: false)
        flashTasks[paneID] = nil
    }
}
