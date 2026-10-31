// MenuBarActions.swift
// Weir — what the menu bar extra does: open a row in Weir, answer it there, or decide, resume, or ask in place.

import AppKit
import WeirDomain

@MainActor
enum MenuBarActions {
    /// The menu's own window, which SwiftUI does not hand out.
    final class MenuWindow {
        /// `nil` until the menu's content is in its window.
        weak var window: NSWindow?
    }

    /// The ledger's entry for an approval or a question; `nil` for anything
    /// else, or a request the ledger no longer holds.
    private static func entry(_ id: AttentionItemID, state: AppState) -> ApprovalLedger.Entry? {
        switch id {
        case let .approval(key), let .question(key):
            state.approvalPresentation.ledger.entries[key]
        case .prompt, .stop, .unread:
            nil
        }
    }

    /// The request behind an approval or a question, as the menu shows it.
    static func request(for id: AttentionItemID, state: AppState) -> MenuBarModel.Request? {
        entry(id, state: state).map { MenuBarModel.Request($0.presentation, state: $0.state) }
    }

    /// Whether the stop `id` can resume in the same conversation, as its
    /// decision bar last read it (`StopLedgerStore.offers`): the pane's job
    /// is read on a timer, not while drawing, and read again at the press.
    static func canResume(_ id: AttentionItemID, state: AppState) -> Bool {
        [.available, .failed].contains(state.stopLedger.offers[id] ?? .unavailable)
    }

    /// What a usage limit stop offers while its limit holds, as its
    /// decision bar reads it (`UsageLimitResetNotice`).
    static func resetNotice(_ id: AttentionItemID, state: AppState, now: Date) -> UsageLimitResetNotice? {
        guard let item = state.attentionQueue.queue.item(id) else { return nil }
        return state.usageLimitResetSync?.notice(for: item, now: now)
    }

    /// Whether the item has a pane to go to, rather than a card to open.
    static func isInPane(_ id: AttentionItemID, state: AppState) -> Bool {
        state.attentionQueue.queue.item(id)?.subject.paneID != nil
    }

    /// A button under a row: it acts at once and leaves Weir, and the
    /// menu, as they are, so the next row can be settled from here too.
    static func perform(_ action: MenuBarModel.Action, on id: AttentionItemID, state: AppState) {
        switch action {
        case .allowOnce:
            decide(id, .allowOnce, state: state)
        case .deny:
            decide(id, .deny, state: state)
        case .resume:
            resume(id, state: state)
        case .notifyAtReset:
            _ = SupervisionWindowActions.requestResetNotice(id, state: state)
        }
    }

    /// Runs the row's own button, the list's Answer…. It takes the person into
    /// Weir, so the menu closes first, as Esc would, and does not stay
    /// over the window it opened.
    static func perform(_ action: NeedsAttentionListModel.RowAction, on id: AttentionItemID, state: AppState, menuWindow: MenuWindow) {
        close(menuWindow)
        switch action {
        case .answer:
            answer(id, state: state)
        }
    }

    /// The row itself: the menu closes, and Weir comes to the front at
    /// the item's pane. ⌘-click opens an item of a project no window shows
    /// in a new window, as the Needs Attention list does.
    static func open(_ id: AttentionItemID, opening: NeedsAttentionListOpening, state: AppState, menuWindow: MenuWindow) {
        close(menuWindow)
        open(id, opensInNewWindow: opening.opensInNewWindow, state: state)
    }

    /// The heading's Open Weir: the window commands act on, brought back
    /// if hidden or minimized, in front, on whatever it shows.
    static func openWeir(state: AppState, menuWindow: MenuWindow) {
        close(menuWindow)
        NSApp.activate()
        state.windowRegistry.bringBack(nil)
    }

    /// The heading's Settings…, through `openSettings`, which the view
    /// holds (`OpenWindowAction`). The menu does not make Weir active,
    /// so the window would open behind the app in front without it.
    static func openSettings(menuWindow: MenuWindow, _ openSettings: () -> Void) {
        close(menuWindow)
        NSApp.activate()
        openSettings()
    }

    /// The heading's Quit Weir, as the app menu's quits, through the
    /// same gate (`AppState+QuitGate`), whose confirmation then opens in
    /// front rather than behind the app the person was in.
    static func quit(menuWindow: MenuWindow) {
        close(menuWindow)
        NSApp.activate()
        NSApp.terminate(nil)
    }

    /// Closes the menu the way Esc does, through its own cancel action, so
    /// SwiftUI knows it is closed: there is no public call for it, and
    /// closing its window behind SwiftUI's back takes two clicks to open
    /// it again. Sent only while the menu holds the keyboard, so Esc never
    /// reaches another window's card or sheet instead.
    private static func close(_ menuWindow: MenuWindow) {
        guard let window = menuWindow.window, window.isKeyWindow else { return }
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
    }

    /// "Allow Once" or "Deny", for a request the menu offers them for, read
    /// again at the press: the request may have been answered elsewhere
    /// since the menu was drawn. Both rules hold, as when the menu drew the
    /// buttons: the menu's (`MenuBarApprovalRule`), and the list's, that
    /// the broker still takes a decision (`AttentionItem.canAnswerInWeir`).
    /// Weir stays where it is.
    private static func decide(_ id: AttentionItemID, _ resolution: ApprovalResolution, state: AppState) {
        guard let entry = entry(id, state: state),
              state.attentionQueue.queue.item(id)?.canAnswerInWeir == true,
              MenuBarModel.Request(entry.presentation, state: entry.state).offer == .allowOrDeny
        else { return }
        state.approvalPresentation.resolve(entry.presentation, resolution)
    }

    /// "Answer…": Weir comes to the front with the request's card open,
    /// as a notification opens it, in `answerWindow`, with neither the
    /// window nor the pane changed.
    ///
    /// A request the card can no longer hold, read again at the press (it
    /// went to the terminal, or its time ran out, after the menu was drawn),
    /// is answered only at its pane: the press goes there, as the row
    /// itself would, and that does switch the window, as opening a pane does. The
    /// rule that answering moves no window is the card's, and no card
    /// opens then; doing nothing would leave the person a press that
    /// answered nothing and a closed menu.
    private static func answer(_ id: AttentionItemID, state: AppState) {
        guard let entry = entry(id, state: state), entry.presentation.supportsNativeAnswer,
              entry.state.acceptsDecision
        else {
            open(id, opensInNewWindow: false, state: state)
            return
        }
        NSApp.activate()
        answerWindow(registry: state.windowRegistry).approvalCard.present(entry.presentation, from: state.approvalPresentation)
    }

    /// The window "Answer…" opens the card in: the one commands act on,
    /// brought back if hidden or minimized, on whatever it shows. Not a
    /// move to the request's project (`WindowRegistry.bringBack`).
    static func answerWindow(registry: WindowRegistry) -> ProjectWindowState {
        registry.bringBack(nil)
    }

    /// A row opened: Weir comes to the front at the item's pane, as the
    /// Needs Attention list opens it: the window commands act
    /// on, brought back if hidden, switches to the item's project in place,
    /// unless another window shows that project and comes forward instead.
    private static func open(_ id: AttentionItemID, opensInNewWindow: Bool, state: AppState) {
        guard let item = state.attentionQueue.queue.item(id) else { return }
        NSApp.activate()
        state.attentionQueue.focus(item, from: nil, opensInNewWindow: opensInNewWindow)
    }

    /// "Resume Same Conversation", as the stop's decision bar resumes it.
    /// Weir stays where it is: no window is shown or made. The resume is
    /// kept against the window that shows the pane, else the project's, else
    /// the one commands act on.
    private static func resume(_ id: AttentionItemID, state: AppState) {
        guard let item = state.attentionQueue.queue.item(id), let record = state.stopLedger.ledger.record(id) else { return }
        let window = resumeWindow(
            paneID: record.paneID,
            projectID: item.subject.projectID,
            session: state.session,
            registry: state.windowRegistry
        )
        SupervisionWindowActions.perform(.resume(id), inPane: record.paneID, window: window, state: state)
    }

    /// The window a resume from the menu is kept against: the one that
    /// shows the pane, else the one that shows its project, else the one
    /// commands act on. Only looked up, never shown or switched: unlike
    /// opening the row, the resume leaves Weir as it is.
    static func resumeWindow(paneID: UUID, projectID: UUID?, session: WorkspaceSession, registry: WindowRegistry) -> ProjectWindowState {
        session.window(showingPane: paneID).flatMap(registry.window)
            ?? projectID.flatMap { registry.window(showingProject: $0, in: session) }
            ?? registry.backgroundCommandTarget
    }
}
