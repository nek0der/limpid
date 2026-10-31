// RestoreText.swift
// Weir — what restoring the code to the start of a turn says: the confirmation, why it cannot run, how it ended, and the record.

import Foundation
import WeirDomain

/// The words of a restore. The record and the strip say what
/// the working tree holds now and what the conversation does not know; a
/// refusal or a stop says whether files were written, which is what the
/// person needs before anything else.
enum RestoreText {

    // MARK: - Entry points

    /// "Restore Code to Before This Turn…", or "Restore Code to Before
    /// T5…" where "this turn" would be unclear (the bar over several
    /// unread turns, the palette).
    static func entry(turnNumber: Int? = nil, locale: Locale) -> String {
        entryResource(turnNumber: turnNumber).resolved(in: locale)
    }

    /// `entry` unresolved, for a menu that resolves its titles when it
    /// opens (`PopUpMenuItem`).
    static func entryResource(turnNumber: Int? = nil) -> LocalizedStringResource {
        guard let turnNumber else { return RestoreGate.entryTitle }
        return LocalizedStringResource(
            "Restore Code to Before T\(turnNumber)…",
            comment: "Decision bar's ⋯ and the palette: opens the confirmation to restore the code; the turn number, as in T5"
        )
    }

    /// Why the restore cannot run now (`RestoreGate.Blocker`).
    static func blocker(_ blocker: RestoreGate.Blocker, locale: Locale) -> String {
        switch blocker {
        case .notRecorded:
            LocalizedStringResource(
                "This turn’s start wasn’t recorded, so the code can’t be restored to it.",
                comment: "Restore: why it is unavailable; the turn's begin snapshot was not taken"
            ).resolved(in: locale)
        case .turnRunning:
            LocalizedStringResource(
                "Unavailable while the turn is running.",
                comment: "Restore: why it is unavailable"
            ).resolved(in: locale)
        case let .agentRunning(other?):
            LocalizedStringResource(
                "Unavailable while \(SessionRowFactText.agentName(.agent(other), locale: locale)) is running in the same worktree.",
                comment: "Restore: why it is unavailable; argument: another agent's name, as Codex"
            ).resolved(in: locale)
        case .agentRunning(nil):
            LocalizedStringResource(
                "Unavailable while an agent is running.",
                comment: "Restore: why it is unavailable"
            ).resolved(in: locale)
        case .agentWaiting:
            LocalizedStringResource(
                "Unavailable while an agent is waiting for an approval or an answer.",
                comment: "Restore: why it is unavailable"
            ).resolved(in: locale)
        case .restoring:
            LocalizedStringResource(
                "A restore or a discard of this worktree is in progress.",
                comment: "Restore and review discard: why it is unavailable; another operation of the worktree runs"
            ).resolved(in: locale)
        }
    }

    // MARK: - The confirmation strip

    static func stripTag(locale: Locale) -> String {
        LocalizedStringResource(
            "Restore",
            comment: "Decision bar's restore strip and record: the tag; and the strip's Restore Code, in a pane too narrow for it"
        ).resolved(in: locale)
    }

    /// "Discard the changes in T5–T7 (+94 −2) and restore the code to
    /// before turn 5." The turns are written as every run of turns is
    /// (「T5〜T7」 in Japanese).
    static func confirmation(first: Int, last: Int, added: Int, removed: Int, locale: Locale) -> String {
        let range = ReceiptText.turns(first...max(first, last), locale: locale)
        // Counted as the panel and the receipt count lines, grouped.
        let diff = "\(ReceiptText.signed(added, sign: "+", locale: locale)) \(ReceiptText.signed(removed, sign: "−", locale: locale))"
        return LocalizedStringResource(
            "Discard the changes in \(range) (\(diff)) and restore the code to before turn \(first).",
            comment: "Restore strip; arguments: the turns undone (T5–T7), lines added and removed (+94 −2), the turn's number"
        ).resolved(in: locale)
    }

    /// What the question's counts leave out in a shared worktree: they are
    /// this conversation's turns, the only ones the panel lists.
    static func countsOwnTurnsOnly(locale: Locale) -> String {
        LocalizedStringResource(
            "The counts don’t include the lines of other conversations’ turns in this worktree.",
            comment: "Restore strip: the question's tooltip, after the question, when other agents are in the worktree"
        ).resolved(in: locale)
    }

    /// What stays, and, with other agents in the worktree, what goes too.
    static func confirmationNote(isShared: Bool, locale: Locale) -> String {
        let stays = LocalizedStringResource(
            "The conversation, staged changes, and commits aren’t changed",
            comment: "Restore strip: what a restore does not touch"
        ).resolved(in: locale)
        guard isShared else { return stays }
        let shared = LocalizedStringResource(
            "Changes by other agents in this worktree and manual edits are also restored",
            comment: "Restore strip: a restore also takes back the other agents' and the person's changes in the worktree"
        ).resolved(in: locale)
        return "\(stays) · \(shared)"
    }

    static func restoreCode(locale: Locale) -> String {
        LocalizedStringResource("Restore Code", comment: "Restore strip: runs the restore").resolved(in: locale)
    }

    /// "Restore", the strip's "Restore Code" in a pane too narrow for it;
    /// VoiceOver still reads the whole.
    static func restoreCodeShort(locale: Locale) -> String {
        LocalizedStringResource(
            "Restore",
            comment: "Decision bar's restore strip and record: the tag; and the strip's Restore Code, in a pane too narrow for it"
        ).resolved(in: locale)
    }

    static func restoring(locale: Locale) -> String {
        LocalizedStringResource("Restoring…", comment: "Restore strip: the restore is running").resolved(in: locale)
    }

    // MARK: - How it ended

    /// What the strip says once the restore ended short of the working
    /// tree whole. One in it whole has no sentence here: the bar's "Done"
    /// line and the record say so.
    static func ended(_ shortfall: RestoreEnding.Shortfall, locale: Locale) -> String {
        switch shortfall {
        case let .partial(kept, failed, keptAside):
            partial(kept: kept, failed: failed, keptAside: keptAside, locale: locale)
        case .canceled(.otherChanges):
            LocalizedStringResource(
                "Restore canceled. Other changes were found, so no files were changed.",
                comment: "Restore strip: a file changed while the restore ran; it took back what it wrote"
            ).resolved(in: locale)
        case let .canceled(.refused(refusal)):
            canceled(because: Self.refusal(refusal, locale: locale), locale: locale)
        case .canceled(.unknown):
            canceled(because: nil, locale: locale)
        case .unknown:
            LocalizedStringResource(
                "Couldn’t tell how the restore ended. Check the working tree before going on.",
                comment: "Restore strip: the restore's journal could not be read to its end"
            ).resolved(in: locale)
        }
    }

    /// "Restore canceled." and why; with no reason given, that no file was
    /// changed, which is what the person needs to know.
    static func canceled(because reason: String?, locale: Locale) -> String {
        guard let reason else {
            return LocalizedStringResource(
                "Restore canceled. No files were changed.",
                comment: "Restore strip: the restore wrote nothing, for no reason the person can act on"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "Restore canceled. \(reason)",
            comment: "Restore strip: the restore wrote nothing; argument: why"
        ).resolved(in: locale)
    }

    /// Part of the restore is in the working tree: what was kept as
    /// another writer left it, what could not be written, and where a save
    /// made meanwhile was put.
    private static func partial(
        kept: [String],
        failed: [String],
        keptAside: [RestoreKeptAside],
        locale: Locale
    ) -> String {
        var sentences = [
            LocalizedStringResource(
                "Restored only part of the code.",
                comment: "Restore strip: the restore stopped partway; what stayed may follow"
            ).resolved(in: locale)
        ]
        if !kept.isEmpty {
            sentences.append(LocalizedStringResource(
                "Kept the files changed meanwhile: \(listed(kept, locale: locale)).",
                comment: "Restore strip: files another writer changed while the restore ran, left as they were; argument: the paths"
            ).resolved(in: locale))
        }
        if !failed.isEmpty {
            sentences.append(LocalizedStringResource(
                "Couldn’t write: \(listed(failed, locale: locale)).",
                comment: "Restore strip: files the restore could not write; argument: the paths"
            ).resolved(in: locale))
        }
        if let aside = keptAsideSentence(keptAside, locale: locale) {
            sentences.append(aside)
        }
        return joined(sentences, locale: locale)
    }

    /// "Saves made meanwhile were moved to .weir-…/out/a.txt.": where to
    /// find what another writer saved through a file the operation had
    /// already taken out. `nil` when there is none.
    static func keptAsideSentence(_ keptAside: [RestoreKeptAside], locale: Locale) -> String? {
        guard !keptAside.isEmpty else { return nil }
        return LocalizedStringResource(
            "Saves made meanwhile were moved to \(listed(keptAside.map(\.location), locale: locale)).",
            comment: "Restore: a save made into a file the operation took out was moved aside; argument: where, relative to the worktree"
        ).resolved(in: locale)
    }

    /// Where an operation put saves made meanwhile, for a toast: a note on
    /// a hunk or a record may be replaced, and the person has to hear it
    /// once. `nil` when it put none.
    static func keptAsideNews(
        _ outcome: RestoreOutcome?,
        besides earlier: [RestoreKeptAside] = [],
        locale: Locale
    ) -> String? {
        guard case let .finished(journal)? = outcome else { return nil }
        // An undo's record carries the saves of the operation it undid,
        // which were told when they were moved.
        return keptAsideSentence(journal.stage.keptAside.filter { !earlier.contains($0) }, locale: locale)
    }

    /// A toast's news and then a note on it, run on as sentences are: with
    /// a space in English, with none in Japanese, where the news already
    /// ends with its full stop.
    static func toast(_ news: String, note: String?, locale: Locale) -> String {
        guard let note else { return news }
        return LocalizedStringResource(
            "toast.withNote",
            defaultValue: "\(news) \(note)",
            comment: "Toast: its news, then a note on it; arguments: the news, the note"
        ).resolved(in: locale)
    }

    /// Sentences, one after another, as the locale runs them on.
    static func joined(_ sentences: [String], locale: Locale) -> String {
        guard let first = sentences.first else { return "" }
        return sentences.dropFirst().reduce(first) { text, next in
            // Sentences run on with a space in English, with none in
            // Japanese.
            LocalizedStringResource(
                "restore.sentences",
                defaultValue: "\(text) \(next)",
                comment: "Restore strip: one sentence after another; arguments: the text so far, the next sentence"
            ).resolved(in: locale)
        }
    }

    /// Why Rust refused, under the worktree lock (`RestoreRefusal`); `nil`
    /// for a reason the person cannot act on.
    static func refusal(_ refusal: RestoreRefusal, locale: Locale) -> String? {
        switch refusal {
        case let .agentActive(provider?):
            blocker(.agentRunning(other: provider), locale: locale)
        case .agentActive(nil):
            blocker(.agentRunning(other: nil), locale: locale)
        case .agentRecording, .agentStarted:
            LocalizedStringResource(
                "An agent started a turn in this worktree.",
                comment: "Restore: refused because an agent began a turn"
            ).resolved(in: locale)
        case .turnNotCaptured:
            blocker(.notRecorded, locale: locale)
        case .mergeInProgress:
            LocalizedStringResource(
                "A merge, a rebase, or a conflict is in progress.",
                comment: "Restore: refused during a merge or a rebase"
            ).resolved(in: locale)
        case .headMoved, .branchChanged:
            LocalizedStringResource(
                "The branch or its commits changed since that turn.",
                comment: "Restore: refused because HEAD or the branch moved since the turn"
            ).resolved(in: locale)
        case .unsupportedVolume:
            LocalizedStringResource(
                "These files can’t be swapped in one step where they are, so this isn’t available here.",
                comment: "Restore or discard: refused where files cannot be swapped in one step (FAT, exFAT, network, a nested volume)"
            ).resolved(in: locale)
        case let .renamedInPlace(paths):
            LocalizedStringResource(
                "It renames files to names this volume takes as the same, such as a case change: \(listed(paths, locale: locale)).",
                comment: "Restore: refused to rename files to names the volume takes as the same (a case change only); argument: the paths"
            ).resolved(in: locale)
        case let .converted(paths):
            LocalizedStringResource(
                "Git now converts these files on writing, so they wouldn’t get their bytes back: \(listed(paths, locale: locale)).",
                comment: "Undo of a discard: refused as Git converts the files on checkout; argument: the paths"
            ).resolved(in: locale)
        case let .pathsInTheWay(paths):
            LocalizedStringResource(
                "It would overwrite files no snapshot holds: \(listed(paths, locale: locale)).",
                comment: "Restore: refused to write over ignored or large files; argument: the paths"
            ).resolved(in: locale)
        case let .changedSinceRestore(paths):
            LocalizedStringResource(
                "Files changed since then: \(listed(paths, locale: locale)).",
                comment: "Undo of a restore or a discard: refused because files changed since it ran; argument: the paths"
            ).resolved(in: locale)
        case .sparseCheckout:
            LocalizedStringResource(
                "This worktree is a sparse checkout.",
                comment: "Restore: refused in a sparse checkout"
            ).resolved(in: locale)
        case .notARepository, .turnNotFound, .otherWorktree, .lockUnavailable, .restoreNotFound, .notUndoable,
             .journalUnwritable, .journalUnreadable, .git, .unknown:
            nil
        }
    }

    /// The first three paths in the locale's list, then how many more:
    /// "a, b, c, and 2 more", 「a、b、c ほか 2 件」.
    static func listed(_ paths: [String], locale: Locale) -> String {
        let shown = paths.prefix(3).formatted(.list(type: .and, width: .narrow).locale(locale))
        guard paths.count > 3 else { return shown }
        return LocalizedStringResource(
            "\(shown), and \(paths.count - 3) more",
            comment: "A list of paths cut short; arguments: the first paths, how many more"
        ).resolved(in: locale)
    }

    // MARK: - The record

    /// "Restored to before T5", or "Partly restored to before T5" when part
    /// of it stayed (a stop, another writer, a crash).
    static func record(_ journal: RestoreJournal, locale: Locale) -> String {
        let isPartial = if case .partiallyApplied = journal.stage {
            !journal.stage.isWhole
        } else {
            false
        }
        return record(turnNumber: journal.turnNumber, isPartial: isPartial, locale: locale)
    }

    /// A journal written before journals named the turn says only that the
    /// code was restored.
    static func record(turnNumber: Int?, isPartial: Bool, locale: Locale) -> String {
        guard let number = turnNumber else {
            return isPartial
                ? LocalizedStringResource(
                    "The code was partly restored",
                    comment: "Restore record: the restore stopped partway; its turn is not known"
                ).resolved(in: locale)
                : LocalizedStringResource(
                    "The code was restored",
                    comment: "Restore record; its turn is not known"
                ).resolved(in: locale)
        }
        if isPartial {
            return LocalizedStringResource(
                "Partly restored to before T\(number)",
                comment: "Restore record: the restore stopped partway; argument: the turn's number, as in T5"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "Restored to before T\(number)",
            comment: "Restore record; argument: the turn's number, as in T5"
        ).resolved(in: locale)
    }

    static func notInConversation(locale: Locale) -> String {
        LocalizedStringResource(
            "Not reflected in the conversation",
            comment: "Restore record: the agent's conversation does not know the code was restored"
        ).resolved(in: locale)
    }

    static func recordHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "restore.recordHelp",
            defaultValue: """
            Only the working tree was restored. The conversation, staged changes, and commits are as they were. \
            To tell the agent, include it in your next instruction.
            """,
            comment: "Restore record: what 'Not reflected in the conversation' means, and what to do about it"
        ).resolved(in: locale)
    }

    static func undoRestore(locale: Locale) -> String {
        LocalizedStringResource("Undo Restore", comment: "Restore record: takes the restore back").resolved(in: locale)
    }

    /// "Undo", for a decision bar too narrow for `undoRestore`: the line
    /// beside it says the restore was done.
    static func undoRestoreShort(locale: Locale) -> String {
        LocalizedStringResource(
            "Undo",
            comment: "Takes back the last move: a toast's, the decision bar's after Mark as Viewed, or a restore's"
        ).resolved(in: locale)
    }

    /// How the last "Undo Restore" fell short, as its record says.
    static func undoResult(_ result: RestoreCoordinator.UndoResult, locale: Locale) -> String {
        UndoOutcomeText.message(result, operation: .restore, locale: locale)
    }
}
