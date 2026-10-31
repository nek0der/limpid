// RestoreActions.swift
// Weir — opening the restore strip from any entry, running the restore it confirms, and taking one back.

import Foundation
import SwiftUI

/// What every restore entry does. Each opens the same strip, in the
/// decision bar of the pane whose agent ran the turn, so the question is
/// asked where its answer shows; the strip runs the restore once the gate
/// lets it, and the record takes it back.
@MainActor
enum RestoreActions {
    /// Opens the restore strip for `turn` in front of the person: the
    /// pane's tab comes forward, out from behind the review tab, and the
    /// strip takes the keyboard. Returns the pane whose bar shows it, `nil`
    /// when the window has no pane and no worktree to open one in.
    @discardableResult
    static func ask(_ turn: TurnSummary, window: ProjectWindowState, state: AppState) -> UUID? {
        guard let pane = pane(for: turn, window: window, state: state) else { return nil }
        if let tabID = state.session.tab(containing: pane)?.id {
            PaneActions.activateAndFocus(
                state.session,
                registry: state.registry,
                tabID: tabID,
                paneID: pane,
                in: window.id,
                intent: .person
            )
            ReviewTabActions.putBehind(
                window: window,
                session: state.session,
                registry: state.registry,
                paneVisibility: PaneVisibilityReporter(windowID: window.id, registry: state.windowRegistry)
            )
        }
        // A restore under way keeps its strip, which says how it ends.
        if window.restoreStrips[pane]?.phase == .running {
            return pane
        }
        window.restoreStrips[pane] = RestoreStrip(turnID: turn.turnID)
        // A request waiting in the pane keeps the bar (`RestoreStrip.yields`),
        // and the keyboard with the terminal, where it is answered.
        if !RestoreStrip.yields(to: state.attentionQueue.queue.items(inPane: pane)) {
            window.restoreFocusRequest = pane
        }
        return pane
    }

    /// The turn the palette's entry restores to (`RestoreEntryTarget`): in
    /// the conversation of the agent in the window's focused pane, else,
    /// when that one has none to restore to (an agent begun anew has no
    /// turn yet), in the one the changes panel's filter narrows the
    /// timeline to.
    static func paletteTarget(window: ProjectWindowState, state: AppState) -> TurnSummary? {
        let focused = window.selection.activeTabID
            .flatMap { state.session.tab($0)?.splitTree.effectiveFocusedLeafID }
            .flatMap { state.attention.headerRuntime(inPane: $0)?.conversation }
        let shown: ConversationKey? = if case let .turns(list) = ChangesPanelActions.content(
            window: window,
            stores: state.changesPanelStores
        ) {
            list.filter
        } else {
            nil
        }
        let restored = state.restoredTurnIDs()
        for conversation in [focused, shown].compactMap(\.self) {
            let turns = state.agentProjection.turnHistory.conversations[conversation] ?? []
            if let turn = RestoreEntryTarget.turn(in: turns, line: state.viewedLines.line(of: conversation), isRestored: {
                restored.contains($0.turnID)
            }) {
                return turn
            }
        }
        return nil
    }

    /// The palette's "Restore Code to Before This Turn…", which this
    /// window runs itself: `.handled` when the strip took the keyboard,
    /// else the terminal gets it back, as after any row.
    static func runFromPalette(window: ProjectWindowState, state: AppState) -> PaletteRowHandling {
        guard let turn = paletteTarget(window: window, state: state),
              let pane = ask(turn, window: window, state: state)
        else { return .handledReturningKeyboard }
        return window.restoreFocusRequest == pane ? .handled : .handledReturningKeyboard
    }

    /// Whether `turnID` is a turn a strip can ask about: one still on
    /// record. One whose start was not recorded opens the strip too, which
    /// says why it cannot run.
    static func canAsk(_ turnID: TurnID, state: AppState) -> Bool {
        state.agentProjection.turnHistory.turn(turnID) != nil
    }

    /// The bar the strip opens in: the pane the turn's conversation runs in
    /// now, else the pane the turn ran in, else the pane the window is on.
    /// With none of those, it opens a shell tab in the window's worktree,
    /// whose pane holds it.
    static func pane(for turn: TurnSummary, window: ProjectWindowState, state: AppState) -> UUID? {
        pane(for: turn, window: window, session: state.session, attention: state.attention)
    }

    static func pane(
        for turn: TurnSummary,
        window: ProjectWindowState,
        session: WorkspaceSession,
        attention: AttentionState
    ) -> UUID? {
        let panes = session.tabs.flatMap { $0.splitTree.allLeafIDs() }
        if let running = panes.first(where: { attention.headerRuntime(inPane: $0)?.conversation == turn.conversation }) {
            return running
        }
        if let recorded = UUID(uuidString: turn.paneID), panes.contains(recorded) {
            return recorded
        }
        if let tabID = window.selection.activeTabID {
            return session.tab(tabID)?.splitTree.effectiveFocusedLeafID
        }
        // The changes panel lists a worktree's turns with no tab open in
        // it, and the strip lives only in a pane's decision bar. A shell
        // tab in that worktree gives it one, where the person goes on from
        // the restored code, rather than a press that does nothing. A
        // selection with no folder (the scratch tabs) lists no turns.
        let container = window.selection.activeContainerID
        guard container.hasParent else { return nil }
        return TabActions.newTab(session, in: container, running: nil, window: window.id, intent: .person, selects: true)
    }

    /// What the strip asks now, `nil` when its turn is gone.
    static func confirmation(for strip: RestoreStrip, state: AppState, locale: Locale) -> RestoreConfirmation? {
        let history = state.agentProjection.turnHistory
        guard let turn = history.turn(strip.turnID) else { return nil }
        let restored = state.restoredTurnIDs()
        return RestoreConfirmation.make(
            turn: turn,
            undone: RestoreConfirmation.undone(by: turn, in: history.conversations) { restored.contains($0.turnID) },
            gate: state.restoreGateInput(for: turn),
            locale: locale
        )
    }

    /// Why `turn` cannot be restored to now (`RestoreGate`).
    static func blocker(_ turn: TurnSummary, state: AppState) -> RestoreGate.Blocker? {
        RestoreGate.blocker(state.restoreGateInput(for: turn))
    }

    static func cancel(paneID: UUID, window: ProjectWindowState) {
        window.restoreStrips[paneID] = nil
    }

    /// "Restore Code": asks the gate again, as the state may have changed
    /// since the strip opened, then runs the restore.
    static func confirm(paneID: UUID, window: ProjectWindowState, state: AppState, locale: Locale) {
        guard var strip = window.restoreStrips[paneID], strip.phase == .confirming,
              let turn = state.agentProjection.turnHistory.turn(strip.turnID)
        else { return }
        if let blocker = blocker(turn, state: state) {
            strip.phase = .ended(RestoreText.canceled(because: RestoreText.blocker(blocker, locale: locale), locale: locale))
            window.restoreStrips[paneID] = strip
            return
        }
        strip.phase = .running
        window.restoreStrips[paneID] = strip
        Task {
            let outcome = await state.restores.restore(turn)
            finish(RestoreEnding(outcome), paneID: paneID, window: window, state: state, locale: locale)
        }
    }

    /// Carries out how the restore ended, as
    /// `RestoreOutcomePresentation.finish` decides it.
    ///
    /// Told where `places(forEndOf:paneID:registry:session:)` says.
    private static func finish(
        _ ending: RestoreEnding,
        paneID: UUID,
        window asked: ProjectWindowState,
        state: AppState,
        locale: Locale
    ) {
        let (window, bar) = places(forEndOf: asked, paneID: paneID, registry: state.windowRegistry, session: state.session)
        let finish = RestoreOutcomePresentation.finish(
            ending,
            history: state.agentProjection.turnHistory.conversations,
            isRoot: state.worktreePaths.isRoot,
            isRecorded: { isRecorded($0, state: state) },
            locale: locale
        )
        switch finish {
        case let .applied(applied):
            bar?.restoreStrips[paneID] = nil
            let moves = SupervisionWindowActions.viewedLineActions(window: window, state: state).markRestored(applied.restoredTurns)
            state.viewedLines.noteRestoreMoves(moves, of: applied.journal.opID, in: applied.journal.root)
            if let bar, bar.decisionBarDone[paneID] != nil {
                bar.decisionBarDone[paneID] = nil
            }
            bar?.pendingDecisionBarDone[paneID] = .restored(applied.done)
            if let toast = applied.toast {
                // Held, not weak: the toast moves to a window left when this
                // one closes (`WindowClosing.tidy`), and the undo then tells
                // its result there (`undo`).
                let journal = applied.journal
                let takeBack = {
                    undo(journal, window: window, state: state)
                }
                state.toastCenter.show(
                    ToastItem(id: toast.id ?? UUID(), message: toast.message, undo: takeBack, undoLabel: toast.undoLabel),
                    in: window.id
                )
            }
        case .closeStrip:
            bar?.restoreStrips[paneID] = nil
        case let .explain(text):
            bar?.restoreStrips[paneID]?.phase = .ended(text)
        }
    }

    /// Where a restore begun in `asked` for the bar of `paneID` tells how
    /// it ended: the toast, with its Undo, and the bar's strip and "Done"
    /// line. In `asked` while it is open. Closed meanwhile, the
    /// toast goes to a window left (`WindowRegistry.windowForResult`), and
    /// the bar's part to the window that draws the pane, or nowhere, the
    /// toast being the way back.
    static func places(
        forEndOf asked: ProjectWindowState,
        paneID: UUID,
        registry: WindowRegistry,
        session: WorkspaceSession
    ) -> (toast: ProjectWindowState, bar: ProjectWindowState?) {
        let told = registry.windowForResult(of: asked, in: session)
        guard told !== asked else { return (asked, asked) }
        return (told, session.window(showingPane: paneID).flatMap { registry.window($0) })
    }

    /// Whether the restore `opID` is the one its worktree's record shows.
    private static func isRecorded(_ opID: String, state: AppState) -> Bool {
        guard let journal = state.restores.journals.values.lazy.flatMap(\.self).first(where: { $0.opID == opID }) else {
            return false
        }
        return record(forRoot: journal.root, state: state)?.opID == opID
    }

    /// "Undo Restore", from the record, the bar's "Done" line, or the
    /// toast, carried out as `RestoreOutcomePresentation.undo` decides.
    static func undo(_ journal: RestoreJournal, window asked: ProjectWindowState, state: AppState) {
        // The record's and the "Done" line's Undo are disabled while
        // another operation of the worktree runs; the toast's cannot be,
        // so a press then is dropped, without a word. No message is needed: the operation under way tells
        // its own end, and the toast is only a help, as the record keeps
        // "Undo Restore" for once it is done. Queuing the press instead
        // would undo a restore after an operation the person never saw
        // end.
        guard !state.restores.isBusy(journal.root) else { return }
        Task {
            let outcome = await state.restores.undo(journal)
            guard let undone = RestoreOutcomePresentation.undo(outcome, of: journal, locale: state.settingsStore.appLocale) else {
                return
            }
            // Told in a window left if this one closed during the wait.
            let window = state.windowRegistry.windowForResult(of: asked, in: state.session)
            if let news = undone.news {
                state.toastCenter.show(ToastItem(message: .verbatim(news), undo: nil), in: window.id)
            }
            // The reading the undo ended with took them back already
            // (`ViewedLineStore.settleRestoreMoves`), unless it could not
            // be read whole.
            let moves = state.viewedLines.takeRestoreMoves(of: undone.opID)
            SupervisionWindowActions.viewedLineActions(window: window, state: state).takeBackRestored(moves)
            for shown in state.windowRegistry.windows {
                for pane in undone.lapsedPanes(in: shown.decisionBarDone) {
                    shown.decisionBarDone[pane] = nil
                }
                for pane in undone.lapsedPanes(in: shown.pendingDecisionBarDone) {
                    shown.pendingDecisionBarDone[pane] = nil
                }
            }
            if let toastID = undone.toastID {
                state.toastCenter.dismiss(toastID)
            }
        }
    }

    /// The restore to show for the worktree at `root`: the latest that can
    /// still be undone, until a turn begins there after it.
    static func record(forRoot root: String, state: AppState) -> RestoreJournal? {
        let isHere = state.worktreePaths.isRoot(root)
        guard let journal = state.restores.journals.first(where: { isHere($0.key) })
            .flatMap({ state.restores.latestUndoable(in: $0.key) })
        else { return nil }
        let history = state.agentProjection.turnHistory.conversations
        return RestoredTurns.isSuperseded(journal, history: history, isRoot: state.worktreePaths.isRoot(journal.root)) ? nil : journal
    }

    /// The restore to show in `paneID`'s bar: the record of the worktree
    /// its agent works in, or, before the agent has said (one started
    /// anew has no prompt or turn yet), of the worktree of the pane's tab.
    static func record(forPane paneID: UUID, state: AppState) -> RestoreJournal? {
        let runtime = state.attention.headerRuntime(inPane: paneID)
        guard let root = runtime?.badge.worktreeRoot ?? runtime?.badge.turnRoot
            ?? state.session.tab(containing: paneID).flatMap({ ReviewAgents.directory(for: $0.container, in: state.session)?.path })
        else { return nil }
        return record(forRoot: root, state: state)
    }

    /// What the window hands its bars and its changes panel for the strip
    /// and the record.
    static func handler(window: ProjectWindowState, state: AppState) -> RestoreHandler {
        RestoreHandler(
            windowID: window.id,
            confirmation: { [state] strip, locale in confirmation(for: strip, state: state, locale: locale) },
            confirm: { [window, state] paneID, locale in confirm(paneID: paneID, window: window, state: state, locale: locale) },
            cancel: { [window] paneID in cancel(paneID: paneID, window: window) },
            record: { [state] paneID in record(forPane: paneID, state: state) },
            journal: { [state] done in state.restores.journal(done.opID, in: done.root) },
            undo: { [window, state] journal in undo(journal, window: window, state: state) },
            isBusy: { [state] root in state.restores.isBusy(root) },
            undoResult: { [state] root in state.restores.undoResults[root] },
            ask: { [window, state] turnID in
                guard let turn = state.agentProjection.turnHistory.turn(turnID) else { return }
                ask(turn, window: window, state: state)
            },
            canAsk: { [state] turnID in canAsk(turnID, state: state) },
            paletteTurnNumber: { [window, state] in paletteTarget(window: window, state: state)?.displayNumber }
        )
    }
}

/// The window's way to the restore strip and record, handed to its bars
/// and its changes panel: what they read and what they run, and no
/// more of the app. Equal by window, as `PrimaryActionHandler` is.
struct RestoreHandler: Equatable, Sendable {
    let windowID: WindowID
    /// What the strip asks now, `nil` when its turn is gone.
    let confirmation: @MainActor @Sendable (RestoreStrip, Locale) -> RestoreConfirmation?
    /// "Restore Code" in the strip of a pane.
    let confirm: @MainActor @Sendable (UUID, Locale) -> Void
    let cancel: @MainActor @Sendable (UUID) -> Void
    /// The record a pane's bar shows at rest.
    let record: @MainActor @Sendable (UUID) -> RestoreJournal?
    /// The journal a "Done" line names, as last read.
    let journal: @MainActor @Sendable (RestoreDone) -> RestoreJournal?
    let undo: @MainActor @Sendable (RestoreJournal) -> Void
    /// Whether a restore or an undo of a worktree is under way.
    let isBusy: @MainActor @Sendable (String) -> Bool
    /// How the last "Undo Restore" of a worktree fell short.
    let undoResult: @MainActor @Sendable (String) -> RestoreCoordinator.UndoResult?
    /// Opens the strip for a turn, in its pane's bar (the bar's ⋯).
    let ask: @MainActor @Sendable (TurnID) -> Void
    let canAsk: @MainActor @Sendable (TurnID) -> Bool
    /// The turn the palette's entry restores to, for its subtitle.
    let paletteTurnNumber: @MainActor @Sendable () -> Int?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.windowID == rhs.windowID
    }
}

extension EnvironmentValues {
    /// `nil` outside a supervision window, which has no strip or record.
    @Entry var restoreHandler: RestoreHandler?
}
