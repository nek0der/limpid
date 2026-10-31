// PaneStripModel+Item.swift
// Weir — the pane strip's item for a tab, as the strip suites read it.

import Foundation
@testable import Weir

extension PaneStripModel {
    /// The strip's item for `tab`, or nil when the strip does not show it.
    func item(for tab: Tab) -> Item? {
        items.first { $0.id == tab.id }
    }
}
