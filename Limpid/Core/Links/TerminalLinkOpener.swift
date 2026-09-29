// TerminalLinkOpener.swift
// Limpid — carries out the action `TerminalLinkPolicy` chose for a clicked
// terminal link.

import AppKit
import Foundation
import OSLog

private let log = Logger.limpid("links")

@MainActor
final class TerminalLinkOpener {
    /// Shows a one-line explanation when a click does something other than
    /// open the target. A closure so Core does not own the toast view state.
    private let notify: (String) -> Void

    init(notify: @escaping (String) -> Void) {
        self.notify = notify
    }

    func open(_ text: String, source: TerminalLinkSource) {
        perform(TerminalLinkPolicy.action(for: text, source: source))
    }

    /// For a click whose target could not be read at all.
    func reject(_ reason: TerminalLinkRejection) {
        perform(.reject(reason))
    }

    private func perform(_ action: TerminalLinkAction) {
        switch action {
        case let .open(url):
            NSWorkspace.shared.open(url)
        case let .reveal(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            notify(String(localized: "Shown in Finder instead of opened, because it can run code."))
        case let .confirm(url):
            confirmAndOpen(url)
        case let .reject(reason):
            log.notice("rejected terminal link: \(String(describing: reason), privacy: .public)")
            notify(reason.message)
        }
    }

    /// A custom scheme can start any application that registered it, so the
    /// prompt names both the target and that application, and only a click
    /// on Open dispatches it. NSAlert gives a button titled Cancel the Escape
    /// key instead of Return, so neither button answers Return and a stray
    /// keystroke cannot accept the prompt.
    private func confirmAndOpen(_ url: URL) {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            notify(String(localized: "No app can open this link."))
            return
        }
        let appName = FileManager.default.displayName(atPath: handler.path)
        let target = TerminalLinkPolicy.displayString(for: url)
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link in \(appName)?")
        alert.informativeText = String(
            localized: "A program in the terminal chose this link, and it may not match the text you clicked.\n\n\(target)"
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSWorkspace.shared.open(url)
    }
}
