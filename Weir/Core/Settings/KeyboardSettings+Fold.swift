// KeyboardSettings+Fold.swift
// Weir — moving the bindings of an action folded into another to the action that took it over.

import Foundation

extension KeyboardSettings {
    /// Moves what a person set for an action folded into another
    /// (`WeirShortcutAction.foldedNames`) to the action that took it over.
    /// That action's own state wins: its own binding, or the person's
    /// Unassign of it, stays, and the folded action's binding is kept aside
    /// in `retired`, listed in Settings until discarded. Otherwise the
    /// binding, or the Unassign, moves over. The folded name holds nothing
    /// afterwards, so running it again changes nothing. `normalize` runs it
    /// first.
    ///
    /// A folded action that kept its default leaves nothing to move: the
    /// file never said so. A binding of the action that took it over then
    /// stands, and the folded default's keys are free.
    mutating func foldActions() {
        for (folded, action) in WeirShortcutAction.foldedNames.sorted(by: { $0.key < $1.key }) {
            let hasOwnChoice = overrides[action.rawValue] != nil || unassigned.contains(action.rawValue)
            if let binding = overrides.removeValue(forKey: folded) {
                if hasOwnChoice {
                    retired[folded] = binding
                } else {
                    overrides[action.rawValue] = binding
                }
            }
            if unassigned.contains(folded) {
                unassigned.removeAll { $0 == folded }
                if !hasOwnChoice, overrides[action.rawValue] == nil {
                    unassigned.append(action.rawValue)
                }
            }
            unbound.removeAll { $0 == folded }
        }
    }
}
