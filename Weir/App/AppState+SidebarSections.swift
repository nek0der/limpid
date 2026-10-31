// AppState+SidebarSections.swift
// Weir — the sections a window's sidebar shows its rows in, read from the app's stores.

import Foundation

extension AppState {
    /// Returns the sections `window`'s sidebar shows every project's rows
    /// in, as it draws them (`ProjectWindowState.presentedSections(session:others:…)`).
    /// They are what ⌃⌘1…9 and ⌘[ ⌘] count of the window's project, and
    /// what the palette lists every project's worktrees by, read the same
    /// way whether or not the sidebar is in sight.
    func sidebarSections(in window: ProjectWindowState) -> SidebarPresentedSections {
        window.presentedSections(
            session: session,
            others: session.otherWindowsByProject(than: window.id),
            queue: attentionQueue.queue,
            pullRequest: { [prStatusStore] in prStatusStore.info(for: $0) },
            gitFacts: { [gitFacts] in gitFacts.facts(for: $0) },
            isDragging: dragState.currentSourceID != nil
        )
    }
}
