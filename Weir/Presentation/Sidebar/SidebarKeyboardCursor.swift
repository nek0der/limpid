// SidebarKeyboardCursor.swift
// Weir — what the arrow keys, Return, and Move Project Up and Down do in the sidebar while it has the keyboard.

import Foundation

/// The sidebar's keys while it has the keyboard (⌥⌘0), as a value: the
/// line they are on and the key decide what happens, so the order is
/// tested without a window.
///
/// - ↑ ↓ go to the line before or after, headers and fold lines included,
///   stopping at the ends.
/// - → opens a folded header or fold line; on an open header it goes to
///   the header's first line. ← folds an open header or fold line; on a row
///   or a closed fold line it goes up to the project's header. With ⌥, ← and →
///   on a header fold or open every header.
/// - Return opens the row, or opens or folds a header or fold line.
/// - Move Project Up and Down (⌥⌘↑ ⌥⌘↓ by default) move the project of
///   the line the keys are on, else the window's project
///   (`SidebarKeyRoute`).
enum SidebarKeyboardCursor {
    enum Key: Equatable {
        case up
        case down
        case left
        case right
        case `return`
    }

    /// What the sidebar does for a key.
    enum Action: Equatable {
        /// The keys go to this line.
        case move(to: SidebarItemID)
        /// Folds (`true`) or opens one header.
        case setCollapsed(UUID, Bool)
        /// Folds or opens every header.
        case setAllCollapsed(Bool)
        /// Opens or folds one of a project's folded sections.
        case setFoldOpen(UUID, SidebarSection, Bool)
        /// Opens the row.
        case activate(ContainerID)
        /// The key does nothing here, and is still the sidebar's.
        case none
    }

    /// What the lines are as the keys see them.
    struct Lines {
        /// Every line in the order drawn, the scratch row last.
        let ids: [SidebarItemID]
        let isCollapsed: (UUID) -> Bool
        let isFoldOpen: (UUID, SidebarSection) -> Bool
    }

    static func action(for key: Key, isOption: Bool, at current: SidebarItemID?, in lines: Lines) -> Action {
        switch key {
        case .up, .down:
            SessionRowNavigation.keyboardStep(from: current, in: lines.ids, forward: key == .down).map { .move(to: $0) } ?? .none
        case .return:
            switch current {
            case let .header(id)?: .setCollapsed(id, !lines.isCollapsed(id))
            case let .fold(id, section)?: .setFoldOpen(id, section, !lines.isFoldOpen(id, section))
            case let .row(row)?: .activate(row)
            case nil: .none
            }
        case .right:
            right(at: current, isOption: isOption, in: lines)
        case .left:
            left(at: current, isOption: isOption, in: lines)
        }
    }

    private static func right(at current: SidebarItemID?, isOption: Bool, in lines: Lines) -> Action {
        switch current {
        case let .header(id)?:
            if isOption {
                return .setAllCollapsed(false)
            }
            if lines.isCollapsed(id) {
                return .setCollapsed(id, false)
            }
            // Open already: into its lines, as a list of folders goes.
            guard let index = lines.ids.firstIndex(of: .header(id)), lines.ids.indices.contains(index + 1),
                  lines.ids[index + 1].projectID == id
            else { return .none }
            return .move(to: lines.ids[index + 1])
        case let .fold(id, section)?:
            return lines.isFoldOpen(id, section) ? .none : .setFoldOpen(id, section, true)
        case .row?, nil:
            return .none
        }
    }

    private static func left(at current: SidebarItemID?, isOption: Bool, in lines: Lines) -> Action {
        switch current {
        case let .header(id)?:
            if isOption {
                return .setAllCollapsed(true)
            }
            return lines.isCollapsed(id) ? .none : .setCollapsed(id, true)
        case let .fold(id, section)?:
            return lines.isFoldOpen(id, section) ? .setFoldOpen(id, section, false) : .move(to: .header(id))
        case let .row(row)?:
            // Up to the project's header; the scratch row has none.
            return row.projectID.map { .move(to: .header($0)) } ?? .none
        case nil:
            return .none
        }
    }

    /// The project Move Project Up and Down move: the one of the line the
    /// keys are on, else the window's.
    static func projectToMove(at current: SidebarItemID?, shown: UUID?) -> UUID? {
        current?.projectID ?? shown
    }
}
