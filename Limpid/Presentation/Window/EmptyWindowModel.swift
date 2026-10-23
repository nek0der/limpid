// EmptyWindowModel.swift
// Limpid — what a window that shows nothing offers: the projects no window shows, in its sidebar's order.

import Foundation

/// The projects a window that shows nothing lists under "Open a Project":
/// those no window shows, hidden ones included, since choosing one
/// another window shows would only bring that window forward. They come in
/// the order the window's sidebar lists them (`SidebarArrangement`), so the
/// two never disagree on where a project is.
struct EmptyWindowModel: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let name: String
        let paletteIndex: Int?
        /// The project's folder, with the home folder as "~".
        let folder: String
    }

    let rows: [Row]

    /// `projects` in the order they are offered.
    init(projects: [Project]) {
        rows = projects.map { project in
            Row(
                id: project.id,
                name: project.name,
                paletteIndex: project.paletteIndex,
                folder: PathFormatting.abbreviateHome(project.rootURL.path)
            )
        }
    }
}

extension EmptyWindowModel {
    /// The list of `window` as the session's windows stand.
    @MainActor
    init(session: WorkspaceSession, window: WindowSelection) {
        let free = Set(session.projectsNoWindowShows(besides: nil).map(\.id))
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        let order = window.sidebarArrangement.ordered(session.projects.map(\.id).filter(free.contains))
        self.init(projects: order.compactMap { byID[$0] })
    }
}
