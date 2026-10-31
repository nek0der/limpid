// TerminalLinkOpener.swift
// Weir — carries out the action `TerminalLinkPolicy` chose for a clicked
// terminal link.

import AppKit
import Foundation
import OSLog

private let log = Logger.weir("links")

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
    /// Shows the confirmation on the terminal's window, or on its own when
    /// it has none, and hands the answer on. The app's (`WindowAlert`), so
    /// Core does not decide how a window presents an alert.
    private let presentAlert: AlertPresenter

    typealias AlertPresenter = @MainActor (
        NSAlert,
        NSWindow?,
        @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) -> Void

    init(
        notify: @escaping (DisplayText) -> Void,
        fileApplication: @escaping () -> FileApplication? = { nil },
        locale: @escaping @MainActor () -> Locale,
        presentAlert: @escaping AlertPresenter
    ) {
        self.notify = notify
        self.fileApplication = fileApplication
        self.locale = locale
        self.presentAlert = presentAlert
    }

    /// `window` is the window of the terminal the link was clicked in,
    /// where a confirmation is shown.
    func open(_ text: String, source: TerminalLinkSource, baseDirectories: [URL] = [], window: NSWindow?) {
        perform(TerminalLinkPolicy.action(for: text, source: source, baseDirectories: baseDirectories), window: window)
    }

    /// For a click whose target could not be read at all.
    func reject(_ reason: TerminalLinkRejection) {
        perform(.reject(reason), window: nil)
    }

    private func perform(_ action: TerminalLinkAction, window: NSWindow?) {
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
            confirmAndOpen(url, window: window)
        case let .reject(reason):
            log.notice("rejected terminal link: \(String(describing: reason), privacy: .public)")
            notify(.localized(reason.message))
        }
    }

    /// A custom scheme can start any application that registered it, so the
    /// prompt names both the target and that application, and only a click
    /// on Open dispatches it. NSAlert gives a button titled Cancel the Escape
    /// key instead of Return, so neither button answers Return and a stray
    /// keystroke cannot accept the prompt. Shown on the terminal's window, so
    /// the prompt says which window's terminal asked.
    private func confirmAndOpen(_ url: URL, window: NSWindow?) {
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
        presentAlert(alert, window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
    }
}
