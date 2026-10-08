// GroupOrProjectID.swift
// Limpid — a Group or a Project, by id: the containers that carry a palette
// color and a settings sheet.

import Foundation

/// Which Group or Project something is about. Carrying the kind with the id
/// (rather than a bare UUID) lets one value drive both kinds through the
/// color picker and the settings sheet.
enum GroupOrProjectID: Hashable, Identifiable {
    case group(UUID)
    case project(UUID)

    var id: UUID {
        switch self {
        case let .group(id), let .project(id): id
        }
    }
}
