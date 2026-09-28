// KeyboardShortcutPresentation.swift
// Limpid — whether the keyboard shortcut cheat sheet is up on the
// main window. Kept off `WindowSession` because it is transient UI
// state that must not be persisted or restored with the session.

import Observation

@MainActor
@Observable
final class KeyboardShortcutPresentation {
    var isPresented: Bool = false

    init() {}
}
