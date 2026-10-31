// RestoreOutcomePresentation.swift
// Weir — what the window does once a restore or its undo ends.

import Foundation
import WeirDomain

/// What the window does once a restore, or an "Undo Restore", ends,
/// decided from how it ended and what the app holds then. The outcome
/// rules live here, as values, so they are the app's and can be checked;
/// `RestoreActions` only carries out what these say.
enum RestoreOutcomePresentation {
    /// What a restore's end does to the strip that ran it, the viewed
    /// lines, the bar's "Done" line, and the toast.
    enum Finish: Equatable {
        /// In the working tree whole: the strip gives way to the bar's
        /// "Done" line and a toast with Undo, and the turns it took back no
        /// longer wait as unviewed.
        case applied(Applied)
        /// The strip closes and says nothing: the record of the worktree,
        /// read again after the restore, shows this restore and says what
        /// it holds.
        case closeStrip
        /// The strip stays, saying how the restore ended, beside the record
        /// when part of it is in the working tree.
        case explain(String)
    }

    struct Applied: Equatable {
        /// The restore, which the toast's Undo takes back.
        let journal: RestoreJournal
        /// The turns whose conversations' viewed lines move below them
        /// (`ViewedLineActions.markRestored`); the moves are kept under the
        /// restore's operation, so "Undo Restore" takes them back even
        /// after a relaunch.
        let restoredTurns: [TurnSummary]
        /// The bar's "Done" line, handed over to show once the pane has
        /// nothing waiting: the unread turns the restore took back leave
        /// the queue only after the projection reads the moved line again,
        /// and a line set over them now would be cleared as the strip gives
        /// way. A line the bar shows already is taken down first, as it
        /// speaks of what came before the restore.
        let done: RestoreDone
        /// `nil` for a journal from a build that did not name the turn:
        /// no toast rather than a wrong number. The record and the "Done"
        /// line still offer the undo.
        let toast: Toast?
    }

    /// The restore's toast, with its Undo.
    struct Toast: Equatable {
        /// The restore's operation, so its undo from elsewhere can take the
        /// toast away; `nil` for an operation not named by a UUID, whose
        /// toast nothing else needs to find.
        let id: UUID?
        let message: DisplayText
        let undoLabel: LocalizedStringResource?
    }

    /// How the end of a restore is taken. `isRoot` gives, for a journal's
    /// root, whether a root a turn's snapshot names is that worktree, which
    /// may be spelled through a link; `isRecorded` whether an operation is
    /// the one its worktree's record shows now, asked only when how the
    /// restore ended is not known, as reading a record walks the history.
    static func finish(
        _ ending: RestoreEnding,
        history: [ConversationKey: [TurnSummary]],
        isRoot: (String) -> (String) -> Bool,
        isRecorded: (String) -> Bool,
        locale: Locale
    ) -> Finish {
        switch ending {
        case let .applied(journal):
            .applied(Applied(
                journal: journal,
                restoredTurns: RestoredTurns.of(journal, history: history, isRoot: isRoot(journal.root)),
                done: RestoreDone(opID: journal.opID, root: journal.root, turnNumber: journal.turnNumber),
                toast: toast(journal, locale: locale)
            ))
        case let .unknown(opID?) where isRecorded(opID):
            // The worktree was read again after the restore, and this
            // restore is in it: its record says what it holds, and a strip
            // saying the end is not known would only contradict it.
            .closeStrip
        case let .partial(_, kept, failed, keptAside):
            .explain(RestoreText.ended(.partial(kept: kept, failed: failed, keptAside: keptAside), locale: locale))
        case let .canceled(reason):
            .explain(RestoreText.ended(.canceled(reason), locale: locale))
        case .unknown:
            .explain(RestoreText.ended(.unknown, locale: locale))
        }
    }

    /// The toast after a whole restore; `nil` when its journal names no
    /// turn.
    private static func toast(_ journal: RestoreJournal, locale: Locale) -> Toast? {
        guard let number = journal.turnNumber else { return nil }
        let kind = ToastKind.codeRestored(turnNumber: number)
        // Saves another writer made meanwhile and the restore moved aside
        // are named with it: nothing else is left to say so. That sentence
        // is resolved now, so this toast alone does not follow a later
        // change of the display language.
        let message: DisplayText = if let aside = RestoreText.keptAsideSentence(journal.stage.keptAside, locale: locale) {
            .verbatim(RestoreText.toast(kind.message.resolved(in: locale), note: aside, locale: locale))
        } else {
            .localized(kind.message)
        }
        return Toast(id: toastID(journal.opID), message: message, undoLabel: kind.undoLabel)
    }

    /// The toast of the restore `opID`, `nil` when it is not named by a
    /// UUID.
    static func toastID(_ opID: String) -> UUID? {
        UUID(uuidString: opID)
    }

    /// What an "Undo Restore" that took its restore back whole does: the
    /// viewed lines go back where the restore found them, and nothing
    /// offers the restore any longer. One that fell short changes none of
    /// that: the record stays and says why (`RestoreCoordinator.undoResults`).
    struct Undo: Equatable {
        /// The restore taken back: its viewed-line moves go back, every
        /// window's "Done" line for it, shown or waiting, goes, and so does
        /// its toast, wherever the undo was pressed.
        let opID: String
        /// Where saves made meanwhile were put, for a toast: told once,
        /// as nothing else says it. `nil` when the undo moved none aside
        /// beyond those the restore already told.
        let news: String?

        var toastID: UUID? {
            RestoreOutcomePresentation.toastID(opID)
        }

        /// The panes in `lines` whose "Done" line offers the restore taken
        /// back, whose Undo would now find nothing.
        func lapsedPanes(in lines: [UUID: DecisionBarContent.DoneResult]) -> [UUID] {
            lines.compactMap { pane, done in done.restores(opID) ? pane : nil }
        }
    }

    /// How the end of an "Undo Restore" of `journal` is taken: `nil` when
    /// it did not run (another operation of the worktree held it, or the
    /// bridge could not be called) or fell short of taking the restore
    /// back whole.
    static func undo(_ outcome: RestoreOutcome?, of journal: RestoreJournal, locale: Locale) -> Undo? {
        guard outcome != nil, RestoreCoordinator.UndoResult(outcome) == nil else { return nil }
        return Undo(
            opID: journal.opID,
            news: RestoreText.keptAsideNews(outcome, besides: journal.stage.keptAside, locale: locale)
        )
    }
}
