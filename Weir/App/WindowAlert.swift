// WindowAlert.swift
// Weir — shows an NSAlert as a sheet on the window it is about, or on its own when there is none.

import AppKit

/// Shows a confirmation about one window (closing its tab or pane, opening a
/// link one of its terminals chose) as a sheet on that window, as SwiftUI's
/// own alerts are, so it is plain which window it asks about. Only an alert
/// with no window to belong to, or whose window cannot take a sheet now,
/// stands on its own.
@MainActor
enum WindowAlert {
    enum Presentation: Equatable {
        /// Attached to the window.
        case sheet
        /// A window of its own, which blocks the whole app.
        case appModal
    }

    /// What decides how an alert can be shown on a window.
    struct Host: Equatable {
        /// On screen: not hidden, not in the Dock.
        var isVisible: Bool
        /// Already showing a sheet. A second one would wait, unseen, until
        /// the first is answered, and the close it asks about with it.
        var hasSheet: Bool
    }

    /// How an alert is shown on `host`, or with no window at all.
    nonisolated static func presentation(on host: Host?) -> Presentation {
        guard let host, host.isVisible, !host.hasSheet else { return .appModal }
        return .sheet
    }

    /// The window a confirmation about `paneIDs` belongs to: the window it
    /// was asked in, when the caller knows it; else the first of the panes
    /// that is drawn in one; else `fallback` (the key window), for a tab
    /// whose panes are not drawn.
    nonisolated static func window<Window>(
        requested: Window?,
        for paneIDs: [UUID],
        windowOf: (UUID) -> Window?,
        fallback: Window?
    ) -> Window? {
        requested ?? paneIDs.lazy.compactMap(windowOf).first ?? fallback
    }

    /// A sheet up now: whether it is its window's only one of its kind, and
    /// how to answer it Cancel and take it down.
    private struct PendingSheet {
        let isExclusive: Bool
        let cancel: @MainActor () -> Void
    }

    /// The sheets up now, by window, then by their answer.
    private static var pending: [ObjectIdentifier: [ObjectIdentifier: PendingSheet]] = [:]

    /// Answers Cancel every sheet up on `window` and takes it down: for a
    /// window going out of sight, where no one could answer them.
    static func cancelPending(on window: NSWindow) {
        for sheet in pending[ObjectIdentifier(window)]?.values ?? [:].values {
            sheet.cancel()
        }
    }

    /// Shows `alert` and hands its answer to `completion`. On a window it is
    /// a sheet, and `completion` runs when the person answers; nothing
    /// waits on it in a modal loop, so the caller goes on with the answer
    /// rather than block for it. If the window closes while the sheet is up,
    /// the answer is Cancel: nothing is done for a window that is gone.
    /// Without a window that can take a sheet, it is an alert of its own,
    /// answered before this returns.
    ///
    /// An `isExclusive` sheet is the window's only one of its kind: asked
    /// again while it is up, the new question is answered Cancel at once,
    /// so a second ⌘W never stacks an alert over the first.
    static func begin(
        _ alert: NSAlert,
        on window: NSWindow?,
        isExclusive: Bool = false,
        completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        if isExclusive, let window,
           pending[ObjectIdentifier(window)]?.values.contains(where: \.isExclusive) == true
        {
            // Heard, so the key press does not look lost.
            NSSound.beep()
            completion(.cancel)
            return
        }
        guard let window, presentation(on: host(of: window)) == .sheet else {
            completion(alert.runModal())
            return
        }
        let key = ObjectIdentifier(window)
        let answer = SheetAnswer(completion)
        let sheetKey = ObjectIdentifier(answer)
        let cancel: @MainActor @Sendable () -> Void = { [weak alert, weak window] in
            answer.parentClosed()
            if let window, let sheet = alert?.window, sheet.sheetParent === window {
                window.endSheet(sheet, returnCode: .cancel)
            }
        }
        // Delivered on the posting thread, the main one, so the answer is
        // given before the window is gone.
        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in
            MainActor.assumeIsolated { cancel() }
        }
        pending[key, default: [:]][sheetKey] = PendingSheet(isExclusive: isExclusive, cancel: cancel)
        answer.onFinish = {
            NotificationCenter.default.removeObserver(observer)
            pending[key]?[sheetKey] = nil
            if pending[key]?.isEmpty == true {
                pending[key] = nil
            }
        }
        alert.beginSheetModal(for: window) { response in
            answer.give(response)
        }
    }

    private static func host(of window: NSWindow) -> Host {
        Host(isVisible: window.isVisible && !window.isMiniaturized, hasSheet: window.attachedSheet != nil)
    }
}

/// The one answer a sheet gives: the person's, or Cancel when its window
/// closes first. Whichever comes first is the answer; a later one is
/// dropped, so the caller never closes something twice, or after it was
/// told no.
@MainActor
final class SheetAnswer {
    private var completion: (@MainActor (NSApplication.ModalResponse) -> Void)?
    /// Run once, when the answer is given: stops watching the window.
    var onFinish: (() -> Void)?

    init(_ completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        self.completion = completion
    }

    func give(_ response: NSApplication.ModalResponse) {
        guard let completion else { return }
        self.completion = nil
        onFinish?()
        onFinish = nil
        completion(response)
    }

    /// The sheet's window closed before the person answered.
    func parentClosed() {
        give(.cancel)
    }
}
