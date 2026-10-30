// SidebarRowDrop.swift
// Limpid — a tab or pane dragged across the sidebar: the rows and headers that take it, the project it marks, and where it lands.

import SwiftUI

/// What a tab or pane dragged across one window's sidebar does: which project it
/// holds open and marks, and the move once it is dropped.
@MainActor
struct SidebarRowDrop {
    let session: WorkspaceSession
    let dragState: LimpidDragState
    let window: WindowID
    let locale: Locale

    /// The projects the drag holds open in this window: the ones it rested
    /// on, and the one it was just dropped into until the arrangement opens
    /// it for good (`SessionSidebarView`).
    var openedByDrag: Set<UUID> {
        let held = dragState.springOpenProjects.union([dragState.keptOpenProject].compactMap(\.self))
        return Set(held.filter { $0.window == window }.map(\.projectID))
    }

    /// The project whose lines the dragged tab or pane is over in this window.
    var carriedOverProjectID: UUID? {
        guard dragState.isCarryingToRow, let project = dragState.carriedOverProject, project.window == window else { return nil }
        return project.projectID
    }

    /// Whether `container`'s row turns the dragged `source` away, a tab or a
    /// pane by the kind of the drag: nothing would move, or the row cannot
    /// take it (`TabActions.wouldMove`).
    func refuses(_ source: UUID, on container: ContainerID) -> Bool {
        let work: CarriedWork = dragState.current == .pane ? .pane(source) : .tab(source)
        return !TabActions.wouldMove(work, to: container, in: session)
    }

    /// What was dragged, named by its `prefix`, dropped on `container`'s row,
    /// or on its project's header for the repository row: it moves there, the
    /// row flashes and the project stays open (`SessionSidebarView`), and
    /// VoiceOver says where it went. A refused drop only lets go of the
    /// project the drag held open.
    func drop(prefix: String, _ source: UUID, on container: ContainerID) {
        let work: CarriedWork = prefix == DragPrefix.pane ? .pane(source) : .tab(source)
        guard TabActions.move(work, to: container, in: session) else {
            dragState.releaseKeptOpen()
            return
        }
        dragState.land(on: container, in: window)
        AccessibilityNotification.Announcement(SidebarDropText.moved(isPane: work.isPane, to: container, in: session, locale: locale))
            .post()
    }
}
