// SidebarItemID.swift
// Limpid — one id for each line of the sidebar's list: project headers, fold lines, and rows alike.

import Foundation

/// What the sidebar's list scrolls to and the arrow keys stop on: a
/// project's header, the line one of its sections folds into, or a row.
/// One type, so a header's id never collides with its folder's row
/// (`.row(.project(id))`), nor one project's fold line with another's.
enum SidebarItemID: Hashable, Sendable {
    case header(UUID)
    case fold(UUID, SidebarSection)
    case row(ContainerID)

    /// The row this line is; `nil` for a header or a fold line.
    var row: ContainerID? {
        if case let .row(row) = self {
            row
        } else {
            nil
        }
    }

    /// The project the line belongs to; `nil` for the scratch row.
    var projectID: UUID? {
        switch self {
        case let .header(id), let .fold(id, _): id
        case let .row(row): row.projectID
        }
    }
}
