// SettingsAwareFindCommands.swift
// Limpid — Routes Find to the focused Settings, Review, or terminal surface.

import SwiftUI

struct SettingsAwareFindCommands: Commands {
    let state: AppState
    @FocusedValue(\.settingsSearchFocusAction) private var settingsSearchFocusAction

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            let performFind: (LimpidShortcutAction) -> Void = { action in
                ReviewPresentationCommand.find(
                    action,
                    session: state.session,
                    presentation: state.reviewPresentation,
                    registry: state.registry
                )
            }
            let focusedPaneID = state.session.activeTab?.splitTree.effectiveFocusedLeafID
            let hasActiveSearch = focusedPaneID.map {
                state.session.paneSearchStates[$0] != nil
            } ?? false

            Section {
                Button {
                    if let settingsSearchFocusAction {
                        settingsSearchFocusAction()
                    } else {
                        performFind(.find)
                    }
                } label: {
                    Label("Find…", systemImage: "magnifyingglass")
                }
                .limpidShortcut(.find, in: state.settingsStore)
                Button {
                    performFind(.findNext)
                } label: {
                    Label("Find Next", systemImage: "chevron.down")
                }
                .limpidShortcut(.findNext, in: state.settingsStore)
                .disabled(!hasActiveSearch && !state.reviewPresentation.isPresented)
                Button {
                    performFind(.findPrevious)
                } label: {
                    Label("Find Previous", systemImage: "chevron.up")
                }
                .limpidShortcut(.findPrevious, in: state.settingsStore)
                .disabled(!hasActiveSearch && !state.reviewPresentation.isPresented)
            }
            .disabled(
                settingsSearchFocusAction == nil
                    && state.session.activeTab == nil
                    && !state.reviewPresentation.isPresented
            )
        }
    }
}
