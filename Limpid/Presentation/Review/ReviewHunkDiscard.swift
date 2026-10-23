// ReviewHunkDiscard.swift
// Limpid — what a review hunk's "Discard" offers, and what a discard of it did.

import Foundation

/// One hunk, as a discard names it: the range (two ranges may end in the
/// same trees), the trees the review diffed, the worktree, the file, and
/// the hunk's `@@` line.
struct ReviewHunkKey: Hashable, Sendable {
    let scopeID: String
    let root: String
    let fromTree: String
    let toTree: String
    let path: String
    let header: String
}

/// What became of a hunk the person discarded, kept by the window while it
/// is open.
enum ReviewHunkDiscardRecord: Equatable, Sendable {
    /// The discard, or its undo, is under way.
    case running
    /// Taken out of the file; the operation `opID` of `root` undoes it.
    /// `note` says why "Undo Discard" did nothing, if it did not.
    case discarded(opID: String, root: String, note: String?)
    /// Perhaps taken out: how the discard ended could not be read. Its
    /// operation `opID` of `root` still offers its undo.
    case uncertain(opID: String, root: String, note: String?)
    /// Not taken out: why.
    case failed(String)

    /// The operation that undoes it, while there is one.
    var operation: (opID: String, root: String)? {
        switch self {
        case let .discarded(opID, root, _), let .uncertain(opID, root, _): (opID, root)
        case .running, .failed: nil
        }
    }

    /// The same record, saying `note`.
    func noting(_ note: String) -> Self {
        switch self {
        case let .discarded(opID, root, _): .discarded(opID: opID, root: root, note: note)
        case let .uncertain(opID, root, _): .uncertain(opID: opID, root: root, note: note)
        case .running, .failed: self
        }
    }
}

/// What a hunk's header offers.
enum ReviewHunkAction: Equatable {
    /// "Discard", off with the reason while it cannot run.
    case discard(blockedReason: String?)
    case running
    /// "Discarded" and "Undo Discard", off with the reason while the undo
    /// cannot run; and the record's note.
    case discarded(blockedReason: String?, note: String?)
    /// Only the note and "Undo Discard": never "Discarded", which is not
    /// known.
    case uncertain(blockedReason: String?, note: String)
    /// Not discarded, and why; "Discard" again.
    case failed(String, blockedReason: String?)
}

enum ReviewHunkDiscardRules {
    /// What the action is worked out from.
    struct Input: Equatable {
        /// Whether the review reads a turn range, whose two trees a discard
        /// diffs again. Other scopes (uncommitted, a branch) have no turn
        /// to gate on, and offer no discard.
        var isTurnRange: Bool
        /// A renamed file's hunks are content of a path the diff paired;
        /// taking them back would not take back the rename.
        var isRenamed: Bool
        /// Why the worktree's gate holds a write back (`RestoreGate`).
        var blocker: RestoreGate.Blocker?
        /// Whether a turn after the range changed the file: its hunks
        /// are not what the file holds now.
        var later: Later = .none
        var record: ReviewHunkDiscardRecord?
    }

    /// What is known of the turns after the range.
    enum Later: Equatable {
        /// No turn of the worktree began after it.
        case none
        /// Git is being asked which paths they changed.
        case checking
        /// Git could not say; the discard waits rather than guess.
        case failed
        /// A turn ended in the same second as the range's end turn, at
        /// another tree: the record keeps seconds, so whether it ended
        /// after the range cannot be told, and the discard is refused
        /// rather than guess (`ReviewHunkDiscardRules.isLaterOrderUnknown`).
        case undecidable
        /// They changed the file; the number is the range's last turn's,
        /// `nil` for a range across conversations, whose last number names
        /// no run.
        case changed(afterTurn: Int?)
        /// They left the file alone.
        case unchanged
    }

    /// What turns after the range changed, as far as Git has said.
    enum LaterPaths: Equatable {
        /// No turn of the worktree began after it.
        case none
        case checking
        case failed
        /// Which of the range's end and another turn's came first is not
        /// recorded (`Later.undecidable`).
        case undecidable
        /// The paths they changed, after the range's last turn (`Later`).
        case known(Set<String>, afterTurn: Int?)
    }

    /// What each hunk of several files offers, by file id and then by the
    /// hunk's `@@` line: the gate once for all of them, and a later turn's
    /// change judged by each file's own path.
    static func actions(
        files: [(file: ReviewFile, headers: [String])],
        blocker: RestoreGate.Blocker?,
        laterPaths: LaterPaths,
        record: (ReviewFile, String) -> ReviewHunkDiscardRecord?,
        locale: Locale
    ) -> [String: [String: ReviewHunkAction]] {
        var byFile: [String: [String: ReviewHunkAction]] = [:]
        for (file, headers) in files {
            let later: Later = switch laterPaths {
            case .none: .none
            case .checking: .checking
            case .failed: .failed
            case .undecidable: .undecidable
            case let .known(paths, lastTurn): paths.contains(file.path) ? .changed(afterTurn: lastTurn) : .unchanged
            }
            var actions: [String: ReviewHunkAction] = [:]
            for header in headers {
                let input = Input(
                    isTurnRange: file.layer == .turns,
                    isRenamed: file.oldPath != nil,
                    blocker: blocker,
                    later: later,
                    record: record(file, header)
                )
                actions[header] = action(input, locale: locale)
            }
            byFile[file.id] = actions
        }
        return byFile
    }

    /// `nil` where the header offers nothing.
    static func action(_ input: Input, locale: Locale) -> ReviewHunkAction? {
        guard input.isTurnRange, !input.isRenamed else { return nil }
        let gateReason = input.blocker.map { RestoreText.blocker($0, locale: locale) }
        switch input.record {
        case .running:
            return .running
        case let .discarded(_, _, note):
            return .discarded(blockedReason: gateReason, note: note)
        case let .uncertain(_, _, note):
            return .uncertain(blockedReason: gateReason, note: note ?? ReviewHunkDiscardText.unknown(locale: locale))
        case let .failed(message):
            return .failed(message, blockedReason: gateReason ?? laterReason(input, locale: locale))
        case nil:
            return .discard(blockedReason: gateReason ?? laterReason(input, locale: locale))
        }
    }

    /// The turn of `last`'s worktree, any conversation's, that ended last
    /// after `last` ended: what it ended with is what the file holds after
    /// the range, as far as turns know. By when each ended, not when
    /// it began, on the worktree's one timeline: a turn of another
    /// conversation that began inside the range and ended after it also
    /// changed the file past the range's end. The range's last turn is the
    /// one whose end tree the range compares (`ReviewTurnRange.endTree`).
    /// Of two of one conversation that ended in the same second, the one
    /// numbered higher ended later: a conversation runs one turn at a time.
    /// So one of `last`'s own conversation numbered after it is later
    /// though it ended in `last`'s second; left out, it would read as a tie
    /// of unknown order (`isLaterOrderUnknown`) and refuse every hunk.
    static func laterTurn(after last: TurnSummary, in turns: [TurnSummary], isRoot: (String) -> Bool) -> TurnSummary? {
        let since = WorktreeTimeline.endDate(last)
        let endedAfterLast = { (turn: TurnSummary) in
            let end = WorktreeTimeline.endDate(turn)
            return end > since
                || end == since && turn.conversation == last.conversation && turn.displayNumber > last.displayNumber
        }
        return turns
            .filter { turn in
                turn.turnID != last.turnID && turn.phase != .started && turn.endTree != nil
                    && (turn.beginTree?.root).map(isRoot) == true && endedAfterLast(turn)
            }
            .max { lhs, rhs in
                let (lhsEnd, rhsEnd) = (WorktreeTimeline.endDate(lhs), WorktreeTimeline.endDate(rhs))
                return lhsEnd != rhsEnd ? lhsEnd < rhsEnd : lhs.displayNumber < rhs.displayNumber
            }
    }

    /// Whether the turn whose end the file holds after the range is not
    /// known: another turn of the worktree ended in the same second as the
    /// one that ended last (`laterTurn`, or `last` when none did), at
    /// another tree, and the record keeps seconds, so which came first is
    /// not known. Two later turns tied this way are as unknown as a
    /// later turn tied with `last`: picking either one compares against a
    /// tree the file may have moved on from. The discard is refused then,
    /// which is the safe side: a discard written against such a tree would
    /// take out what the other turn wrote. One that ended at the same tree
    /// changed nothing after it.
    static func isLaterOrderUnknown(after last: TurnSummary, in turns: [TurnSummary], isRoot: (String) -> Bool) -> Bool {
        later(after: last, in: turns, isRoot: isRoot).isOrderUnknown
    }

    /// This is what turns say of the file after a range: the turn that ended last
    /// after it (`laterTurn`) and whether its order is not known
    /// (`isLaterOrderUnknown`), read in one go so the later turn is looked
    /// for once.
    struct LaterReading: Equatable {
        let turn: TurnSummary?
        let isOrderUnknown: Bool
    }

    static func later(after last: TurnSummary, in turns: [TurnSummary], isRoot: (String) -> Bool) -> LaterReading {
        let turn = laterTurn(after: last, in: turns, isRoot: isRoot)
        return LaterReading(turn: turn, isOrderUnknown: isOrderUnknown(latest: turn ?? last, last: last, in: turns, isRoot: isRoot))
    }

    private static func isOrderUnknown(
        latest: TurnSummary,
        last: TurnSummary,
        in turns: [TurnSummary],
        isRoot: (String) -> Bool
    ) -> Bool {
        let since = WorktreeTimeline.endDate(latest)
        return turns.contains { turn in
            // One numbered before `latest` in its own conversation ended
            // before it: a conversation runs one turn at a time.
            let isEarlierOfItsConversation = turn.conversation == latest.conversation
                && turn.displayNumber < latest.displayNumber
            return turn.turnID != latest.turnID && turn.turnID != last.turnID && !isEarlierOfItsConversation
                && turn.phase != .started
                && (turn.beginTree?.root ?? turn.endTree?.root).map(isRoot) == true
                && WorktreeTimeline.endDate(turn) == since && turn.endTree?.tree != latest.endTree?.tree
        }
    }

    private static func laterReason(_ input: Input, locale: Locale) -> String? {
        switch input.later {
        case .none, .unchanged: nil
        case .checking: ReviewHunkDiscardText.checkingLater(locale: locale)
        case .failed: ReviewHunkDiscardText.laterUnknown(locale: locale)
        case .undecidable: ReviewHunkDiscardText.laterOrderUnknown(locale: locale)
        case let .changed(turnNumber): ReviewHunkDiscardText.changedAfter(turnNumber: turnNumber, locale: locale)
        }
    }

    /// What each hunk asked for became, by `outcome`: discarded with the
    /// operation that undoes it, or not, and why. A bridge that answered
    /// nothing may have written: that is said, never that nothing was; and
    /// a hunk whose end is not known keeps its undo when there is one.
    static func records(
        _ outcome: DiscardOutcome?,
        keys: [ReviewHunkKey],
        locale: Locale
    ) -> [ReviewHunkKey: ReviewHunkDiscardRecord] {
        let unknown = ReviewHunkDiscardRecord.failed(ReviewHunkDiscardText.unknown(locale: locale))
        guard let outcome else {
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, unknown) })
        }
        switch outcome {
        case let .refused(refusal):
            let failed = ReviewHunkDiscardRecord.failed(ReviewHunkDiscardText.refused(refusal, locale: locale))
            return Dictionary(uniqueKeysWithValues: keys.map { ($0, failed) })
        case let .finished(journal, hunks):
            let keptAside: [RestoreKeptAside] = if case let .partiallyApplied(_, _, _, keptAside)? = journal?.stage {
                keptAside
            } else {
                []
            }
            return Dictionary(uniqueKeysWithValues: keys.map { key in
                let result = hunks.first { $0.path == key.path && $0.header == key.header }?.result
                // A save made into the file the discard took out is not
                // lost: the hunk says where it went.
                let note = RestoreText.keptAsideSentence(keptAside.filter { $0.path == key.path }, locale: locale)
                // A hunk not discarded says where a save went, too.
                let failed = { (reason: String) in
                    ReviewHunkDiscardRecord.failed(RestoreText.joined([reason] + [note].compactMap(\.self), locale: locale))
                }
                let record: ReviewHunkDiscardRecord = switch result {
                case .discarded:
                    journal.map { .discarded(opID: $0.opID, root: $0.root, note: note) } ?? unknown
                case .notFound:
                    failed(ReviewHunkDiscardText.notFound(locale: locale))
                case .notWritten:
                    failed(ReviewHunkDiscardText.notWritten(locale: locale))
                case .converted:
                    failed(ReviewHunkDiscardText.converted(locale: locale))
                case .unsupported:
                    failed(ReviewHunkDiscardText.unsupported(locale: locale))
                case .unknown, nil:
                    journal.map { .uncertain(opID: $0.opID, root: $0.root, note: note) } ?? unknown
                }
                return (key, record)
            })
        }
    }
}

/// This keeps what turns say of the file after each range a review reads
/// (`ReviewHunkDiscardRules.later`), for the history and the path
/// spellings it was read from. Every draw of the review tab asks it, as
/// does its task's key, and a comment's keystroke or a selection drag
/// draws again: each reading flattens the whole history and reads every
/// turn's end, however small the file on screen. A new history revision
/// or a forgotten spelling drops every reading, so none outlives what it
/// was read from. A discard asks again past this (`read`) right before it
/// runs.
@MainActor
final class ReviewLaterTurns {
    private struct Key: Hashable {
        let endTurnID: TurnID
        let root: String
    }

    private struct Source: Equatable {
        let historyRevision: Int
        let pathGeneration: Int
    }

    private var source: Source?
    /// A reading is `nil` for a range whose last turn is not recorded.
    private var readings: [Key: ReviewHunkDiscardRules.LaterReading?] = [:]
    /// This counts the readings worked out rather than kept, for tests.
    private(set) var readCount = 0

    /// Returns the reading for `range`, kept while the history and the
    /// spellings stay as they were. It is `nil` when its last turn is not recorded.
    func later(after range: ReviewTurnRange, history: TurnHistory, paths: WorktreePathResolver) -> ReviewHunkDiscardRules.LaterReading? {
        // We read the history's revision on every ask, so a view that draws
        // from a kept reading still observes the history it came from.
        let current = Source(historyRevision: history.revision, pathGeneration: paths.generation)
        if source != current {
            source = current
            readings = [:]
        }
        let key = Key(endTurnID: range.endTurnID, root: range.root)
        if let kept = readings[key] {
            return kept
        }
        readCount += 1
        let reading = Self.read(after: range, history: history, paths: paths)
        readings[key] = reading
        return reading
    }

    /// Works out the reading for `range` now, from the whole history.
    static func read(
        after range: ReviewTurnRange,
        history: TurnHistory,
        paths: WorktreePathResolver
    ) -> ReviewHunkDiscardRules.LaterReading? {
        guard let last = history.turn(range.endTurnID) else { return nil }
        return ReviewHunkDiscardRules.later(
            after: last,
            in: history.conversations.values.flatMap(\.self),
            isRoot: paths.isRoot(range.root)
        )
    }
}

/// The words of a hunk's discard.
enum ReviewHunkDiscardText {
    static func discard(locale: Locale) -> String {
        // Its own key: Settings' "Discard" forgets a shortcut, and one key
        // carries one comment for the translator.
        LocalizedStringResource(
            "review.hunk.discard",
            defaultValue: "Discard",
            comment: "Review: takes a hunk's changes out of the file"
        ).resolved(in: locale)
    }

    static func discardHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "Takes this hunk’s changes out of the file",
            comment: "Review: tooltip of Discard on a hunk"
        ).resolved(in: locale)
    }

    static func discarded(locale: Locale) -> String {
        LocalizedStringResource("Discarded", comment: "Review: a hunk whose changes were taken out of the file").resolved(in: locale)
    }

    static func discarding(locale: Locale) -> String {
        LocalizedStringResource("Discarding…", comment: "Review, VoiceOver: a hunk's discard is running").resolved(in: locale)
    }

    static func undoDiscard(locale: Locale) -> String {
        LocalizedStringResource("Undo Discard", comment: "Review: puts a discarded hunk back").resolved(in: locale)
    }

    /// "This file changed in a turn after T6, so the hunk can’t be
    /// discarded. Start from the latest turn."
    /// Across conversations, "This file changed in a turn after this
    /// scope…": the range's last number is one conversation's, and names
    /// no point of the worktree's timeline.
    static func changedAfter(turnNumber: Int?, locale: Locale) -> String {
        guard let turnNumber else {
            return LocalizedStringResource(
                "This file changed in a turn after this scope, so the hunk can’t be discarded. Start from the latest turn.",
                comment: "Review: why Discard is off for a range across conversations; a later turn of any conversation changed the file"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "This file changed in a turn after T\(turnNumber), so the hunk can’t be discarded. Start from the latest turn.",
            comment: "Review: why Discard is off; argument: the number of the range's last turn, as in T6"
        ).resolved(in: locale)
    }

    static func checkingLater(locale: Locale) -> String {
        LocalizedStringResource(
            "Checking whether a later turn changed this file…",
            comment: "Review: why Discard is off for a moment; Git is asked which files turns after the range changed"
        ).resolved(in: locale)
    }

    static func laterUnknown(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t check whether a later turn changed this file.",
            comment: "Review: why Discard is off; Git could not say which files turns after the range changed"
        ).resolved(in: locale)
    }

    static func laterOrderUnknown(locale: Locale) -> String {
        LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Another turn ended in the same second as this scope’s end, so whether it changed this file afterward can’t be checked, and the hunk can’t be discarded. Start from the latest turn.",
            comment: "Review: why Discard is off; another turn ended in the same second as the range’s end turn, the turn that ended last"
        ).resolved(in: locale)
    }

    /// An undo asked of a discard whose journal has not settled (a hook
    /// held the worktree lock when it was read again).
    static func unsettled(locale: Locale) -> String {
        LocalizedStringResource(
            "The discard hasn’t settled yet. Try again in a moment.",
            comment: "Review: Undo Discard waits; the discard's journal is not settled yet"
        ).resolved(in: locale)
    }

    static func notFound(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t discard. The hunk’s lines changed after the review showed them.",
            comment: "Review: a discard found the hunk's lines changed in the file"
        ).resolved(in: locale)
    }

    static func notWritten(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t discard. The file couldn’t be written, or changed while it was.",
            comment: "Review: a discard could not write the file, or another writer changed it meanwhile"
        ).resolved(in: locale)
    }

    static func converted(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t discard. Git converts this file’s line endings or contents, so it can’t be written back exactly.",
            comment: "Review: a discard refused a file git converts on checkout (line endings, a filter)"
        ).resolved(in: locale)
    }

    static func unsupported(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t discard. A link, a submodule, or a file of another kind is there now.",
            comment: "Review: a discard refused a path that is a link, a submodule, or changed kind since the range"
        ).resolved(in: locale)
    }

    /// The discard's journal could not be read; its record stays.
    static func journalUnread(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t read how the discard ended. Try again in a moment.",
            comment: "Review: Undo Discard could not find the discard's journal for now; the record stays"
        ).resolved(in: locale)
    }

    static func unknown(locale: Locale) -> String {
        LocalizedStringResource(
            "Couldn’t tell whether the hunk was discarded. Check the file.",
            comment: "Review: how a discard ended could not be read"
        ).resolved(in: locale)
    }

    /// Why the worktree's lock-held checks refused: no file was written.
    static func refused(_ refusal: RestoreRefusal, locale: Locale) -> String {
        guard let reason = RestoreText.refusal(refusal, locale: locale) else {
            return LocalizedStringResource(
                "Couldn’t discard. No files were changed.",
                comment: "Review: a discard wrote nothing, for no reason the person can act on"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "Couldn’t discard. \(reason)",
            comment: "Review: a discard wrote nothing; argument: why"
        ).resolved(in: locale)
    }

    /// How "Undo Discard" fell short.
    static func undoFailed(_ result: RestoreCoordinator.UndoResult, locale: Locale) -> String {
        UndoOutcomeText.message(result, operation: .discard, locale: locale)
    }
}
