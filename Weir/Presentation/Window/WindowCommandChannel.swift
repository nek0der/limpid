// WindowCommandChannel.swift
// Weir — one window's commands, handed to the view of that window that carries each out.

import Combine
import Foundation
import OSLog

private let log = Logger.weir("window.command")

/// The commands asked of one window (`WindowCommand`), handed to its views
/// as they are sent (`ProjectWindowState.commands`). Each view that carries
/// some of them out takes the ones it does; a command none took is logged
/// and reported to the sender, where a broadcast would have been dropped
/// without a trace. Delivery is synchronous, on the main actor, to the
/// views on screen at the moment.
@MainActor
final class WindowCommandChannel {
    /// One command on its way to the window's views. A class, so the view
    /// that takes it marks the one every view is handed.
    @MainActor
    final class Request {
        let command: WindowCommand
        private(set) var isTaken = false

        init(_ command: WindowCommand) {
            self.command = command
        }

        func take() {
            isTaken = true
        }
    }

    /// What the window's views receive (`View.onWindowCommand`).
    let requests = PassthroughSubject<Request, Never>()

    /// Hands `command` to the window's views. `false` when none took it.
    @discardableResult
    func send(_ command: WindowCommand) -> Bool {
        let request = Request(command)
        requests.send(request)
        if !request.isTaken {
            log.error("no view of the window took \(String(describing: command), privacy: .private)")
        }
        return request.isTaken
    }
}
