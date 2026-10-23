// KeyboardShortcutPresentation.swift
// Limpid — whether the keyboard shortcuts panel is up over a main
// window. Kept off `WorkspaceSession` because it is transient UI
// state that must not be persisted or restored with the session.

import Observation

@MainActor
@Observable
final class KeyboardShortcutPresentation {
    var isPresented: Bool = false

    init() {}
}
