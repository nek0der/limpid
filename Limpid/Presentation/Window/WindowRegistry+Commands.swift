// WindowRegistry+Commands.swift
// Limpid — a command delivered to the window it is for.

import Foundation
import OSLog

private let log = Logger.limpid("window.command")

extension WindowRegistry: WindowCommandPerforming {
    /// Hands `command` to the views of `id` (`ProjectWindowState.commands`).
    /// A window that is gone runs nothing: what was asked of it is not done
    /// in another.
    @discardableResult
    func perform(_ command: WindowCommand, in id: WindowID) -> Bool {
        guard let window = window(id) else {
            log.error("no open window for \(String(describing: command), privacy: .private)")
            return false
        }
        return window.commands.send(command)
    }
}
