// CarriedWork.swift
// Weir — what a drag to a sidebar row carries: a tab, or a pane out of one.

import Foundation

/// What a drag to a sidebar row carries. The one thing the rule that decides
/// whether a row takes it (`TabActions.wouldMove`), the move, and the words
/// said afterward all tell apart.
package enum CarriedWork: Equatable {
    case tab(UUID)
    case pane(UUID)

    package var isPane: Bool {
        if case .pane = self {
            true
        } else {
            false
        }
    }
}
