// PaneNavigation.swift
// Limpid — jump-to-pane and flash helpers shared across views

import Foundation

@MainActor
func jumpToPane(_ paneID: UUID, session: WindowSession, registry: any SurfaceViewProviding) {
    guard let tab = session.tab(containing: paneID) else { return }
    session.setActiveTab(tab.id)
    session.update(tab.id) { t in
        t.splitTree.focusedLeafID = paneID
    }
    if let view = registry.view(for: paneID) {
        view.window?.makeFirstResponder(view)
    }
    flashPane(paneID, session: session)
}

@MainActor
func flashPane(_ paneID: UUID, session: WindowSession) {
    session.setBell(paneID: paneID, ringing: true)
    Task { @MainActor [weak session] in
        try? await Task.sleep(nanoseconds: LimpidMotion.bellFlashNanoseconds)
        session?.setBell(paneID: paneID, ringing: false)
    }
}
