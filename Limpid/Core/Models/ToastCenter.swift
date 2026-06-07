// ToastCenter.swift
// Limpid — single-slot toast bus. Holds at most one active toast at a
// time (window-scoped). Designed for "undoable destructive lite"
// actions like Hide Worktree: do the thing immediately, surface a
// short-lived banner with an Undo button, auto-dismiss after a few
// seconds. Modeled on the Apple-style "deleted message → Undo"
// pattern (Mail / Notes).
//
// One slot is intentional: stacking toasts on a desktop sidebar
// turned into noise in our prototypes, and the user can always undo
// the most recent action — older actions stay undoable through the
// normal "Show Hidden Worktrees" / context-menu paths.

import Foundation

@MainActor
@Observable
final class ToastCenter {
    /// Currently visible toast, if any. `nil` between toasts.
    var current: ToastItem?

    private var dismissTask: Task<Void, Never>?

    /// Show `item`, replacing any in-flight toast. The previous toast
    /// (if still on screen) is dropped without firing its undo — that
    /// matches the Apple HIG guideline that a fresh action supersedes
    /// the prior reversible state.
    func show(_ item: ToastItem) {
        dismissTask?.cancel()
        current = item
        dismissTask = Task { [weak self, id = item.id, lifetime = item.lifetimeSeconds] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            guard self?.current?.id == id else { return }
            self?.current = nil
        }
    }

    /// Invoke the undo action of the current toast and clear it.
    /// No-op for info-only toasts (`ToastItem.undo == nil`).
    func undo() {
        guard let item = current, let undo = item.undo else { return }
        dismissTask?.cancel()
        current = nil
        undo()
    }

    /// Drop the current toast without calling undo.
    func dismiss() {
        dismissTask?.cancel()
        current = nil
    }
}

/// A single toast payload. Identifiable so the view can drive an
/// `id`-keyed transition when a fresh toast replaces an older one
/// mid-flight.
struct ToastItem: Identifiable {
    let id = UUID()
    /// Pre-localized message. Callers must run the catalog lookup
    /// themselves (typically via `String(localized: "Hid worktree
    /// “\(label)”")`) before constructing the item — `Text(String)`
    /// is not auto-localized, so threading a raw key through here
    /// would silently bypass the String Catalog.
    let message: String
    /// Closure run when the user clicks Undo. The toast is dismissed
    /// before this fires, so the closure can safely re-enter the
    /// model layer. `nil` for info-only toasts whose message has
    /// nothing to reverse (e.g. "Not enough room to split"); the
    /// view hides the Undo button in that case.
    let undo: (() -> Void)?
    /// Seconds before the toast auto-dismisses. 5s matches macOS
    /// Mail's "deleted message" undo window.
    var lifetimeSeconds: Double = 5.0
}
