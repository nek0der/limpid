// WindowCommandReceiver.swift
// Limpid — a view of a main window carrying out the commands asked of that window.

import SwiftUI

extension View {
    /// Carries out the commands asked of `window` that `take` handles: it
    /// returns whether it did, and a command it took is not handed to the
    /// window's other views (`WindowCommandChannel`).
    func onWindowCommand(of window: ProjectWindowState, _ take: @escaping (WindowCommand) -> Bool) -> some View {
        onReceive(window.commands.requests) { request in
            guard !request.isTaken, take(request.command) else { return }
            request.take()
        }
    }
}
