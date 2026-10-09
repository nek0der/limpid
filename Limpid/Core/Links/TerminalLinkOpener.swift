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
    private let notify: (DisplayText) -> Void
    /// Read at click time so a change in Settings applies to the next click.
    private let fileApplication: () -> FileApplication?
    /// The app locale, read when the confirmation is built. An `NSAlert`
    /// is outside SwiftUI's environment, so it would otherwise answer in
    /// the language the process launched with.
    private let locale: @MainActor () -> Locale

    init(
        notify: @escaping (DisplayText) -> Void,
        fileApplication: @escaping () -> FileApplication? = { nil },
        locale: @escaping @MainActor () -> Locale
    ) {
        self.notify = notify
        self.fileApplication = fileApplication
        self.locale = locale
    }

    func open(_ text: String, source: TerminalLinkSource, baseDirectories: [URL] = []) {
        perform(TerminalLinkPolicy.action(for: text, source: source, baseDirectories: baseDirectories))
    }

    /// For a click whose target could not be read at all.
    func reject(_ reason: TerminalLinkRejection) {
        perform(.reject(reason))
    }

    private func perform(_ action: TerminalLinkAction) {
        switch action {
        case let .open(url):
            NSWorkspace.shared.open(url)
        case let .openFile(url, position):
            let application = FileOpener.application(for: fileApplication())
            Task { [notify] in
                do {
                    try await FileOpener.open(url, at: position, with: application)
                } catch {
                    notify(DisplayText(error: error))
                }
            }
        case let .reveal(url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            notify(.localized("Shown in Finder instead of opened, because it can run code."))
        case let .confirm(url):
            confirmAndOpen(url)
        case let .reject(reason):
            log.notice("rejected terminal link: \(String(describing: reason), privacy: .public)")
            notify(.localized(reason.message))
        }
    }

    /// A custom scheme can start any application that registered it, so the
    /// prompt names both the target and that application, and only a click
    /// on Open dispatches it. NSAlert gives a button titled Cancel the Escape
    /// key instead of Return, so neither button answers Return and a stray
    /// keystroke cannot accept the prompt.
    private func confirmAndOpen(_ url: URL) {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            notify(.localized("No app can open this link."))
            return
        }
        let appName = FileManager.default.displayName(atPath: handler.path)
        let target = TerminalLinkPolicy.displayString(for: url)
        let locale = locale()
        let alert = NSAlert()
        alert.messageText = LocalizedStringResource("Open this link in \(appName)?").resolved(in: locale)
        alert.informativeText = LocalizedStringResource(
            "A program in the terminal chose this link, and it may not match the text you clicked.\n\n\(target)"
        ).resolved(in: locale)
        alert.alertStyle = .warning
        alert.addButton(withTitle: LocalizedStringResource("Cancel").resolved(in: locale))
        alert.addButton(withTitle: LocalizedStringResource("Open").resolved(in: locale))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        NSWorkspace.shared.open(url)
    }
}
