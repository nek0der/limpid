// WorkspaceSession+ClosedTabStack.swift
// Weir — undo stack for ⌘⇧T (Reopen Closed Tab). The field lives on
// `WorkspaceSession`, shared by every window, and the push / pop helpers
// live in a focused extension so the model owns its own cap + eviction
// invariant instead of leaking it into the orchestration layer
// (`TabActions`).

import Foundation

@MainActor
extension WorkspaceSession {
    /// Push a snapshot of a tab the user just closed. Caps at
    /// `closedTabStackLimit`; the evicted snapshot's `.vt` files are
    /// deleted on the way out so the scrollback directory stays
    /// bounded. Callers compose the snapshot's `scrollbackPaths`
    /// themselves (they need the registry to ask each `SurfaceView`
    /// to dump its scrollback first).
    func recordClosedTab(_ snapshot: Tab) {
        closedTabStack.append(ClosedTab(tab: snapshot, closedAt: .now))
        if closedTabStack.count > Self.closedTabStackLimit {
            let dropped = closedTabStack.removeFirst()
            for path in dropped.tab.scrollbackPaths.values {
                try? SecureFileWrite.removeItem(at: URL(fileURLWithPath: path))
            }
            // Its panes will never start: their first instructions go too.
            for path in dropped.tab.initialPromptFiles.values {
                InitialPromptFile.remove(path)
            }
        }
    }

    /// Pop the most-recently-closed tab off the stack. Returns nil
    /// when the stack is empty.
    func popClosedTab() -> ClosedTab? {
        closedTabStack.popLast()
    }

    /// Remove a specific closed tab by its original tab id. Used by
    /// the command palette when the user picks a non-latest entry.
    func popClosedTab(id: UUID) -> ClosedTab? {
        guard let idx = closedTabStack.firstIndex(where: { $0.tab.id == id }) else {
            return nil
        }
        return closedTabStack.remove(at: idx)
    }
}
