// UnreadTurnRules.swift
// Weir — which unread items a conversation's turn records ask for.

import Foundation

/// Builds a conversation's unread items from its turns.
///
/// A turn that may have changed files stays unread until the viewed line
/// passes it; all of them below the line make one item ("T6–T7"), with
/// their changes summed, since one "Mark as Viewed" reads them together.
/// A turn that only answered, or whose changes could not be taken, is its
/// own item, read by opening its pane. A turn still running is not unread
/// yet, and an end nobody prompted never is.
package enum UnreadTurnRules {
    /// A runtime as these rules see it.
    package struct Run: Equatable, Sendable {
        package let runtimeID: String
        /// The hook's run ID, which each turn record names.
        package let runID: String
        package let conversation: ConversationKey?
        /// Whether it shows in a pane, where its items can be listed.
        package let hasPane: Bool
        package let updatedAt: Date

        package init(
            runtimeID: String,
            runID: String,
            conversation: ConversationKey?,
            hasPane: Bool,
            updatedAt: Date
        ) {
            self.runtimeID = runtimeID
            self.runID = runID
            self.conversation = conversation
            self.hasPane = hasPane
            self.updatedAt = updatedAt
        }
    }

    /// Each runtime's unread items, by runtime ID. A conversation's items go
    /// to one of its runs, so a conversation resumed in a new run brings
    /// them along and two runs never list them twice; its other runs list
    /// none. The owner is a run shown in a pane before one that is not (the
    /// items would vanish and come back last), then the run of the latest
    /// turn, then the one updated last. A runtime whose conversation the
    /// history does not have yet is left out, and its finished episode is
    /// the unread item (`RuntimeFact.isEpisodeRead`).
    package static func byRuntime(
        _ runs: [Run],
        history: [ConversationKey: [TurnSummary]],
        isRead: (TurnSummary) -> Bool
    ) -> [String: [UnreadTurnEntry]] {
        var owners: [ConversationKey: Run] = [:]
        for run in runs {
            guard let conversation = run.conversation, let turns = history[conversation] else { continue }
            if let owner = owners[conversation], outranks(owner, run, latestRunID: turns.last?.runID) {
                continue
            }
            owners[conversation] = run
        }
        var result: [String: [UnreadTurnEntry]] = [:]
        for run in runs {
            guard let conversation = run.conversation, let turns = history[conversation] else { continue }
            result[run.runtimeID] = owners[conversation] == run
                ? entries(of: conversation, turns: turns, isRead: isRead)
                : []
        }
        return result
    }

    private static func outranks(_ lhs: Run, _ rhs: Run, latestRunID: String?) -> Bool {
        if lhs.hasPane != rhs.hasPane {
            return lhs.hasPane
        }
        let isLhsLatest = lhs.runID == latestRunID
        if isLhsLatest != (rhs.runID == latestRunID) {
            return isLhsLatest
        }
        return (lhs.updatedAt, lhs.runtimeID) > (rhs.updatedAt, rhs.runtimeID)
    }

    package static func entries(
        of conversation: ConversationKey,
        turns: [TurnSummary],
        isRead: (TurnSummary) -> Bool
    ) -> [UnreadTurnEntry] {
        let unread = turns.filter { $0.phase != .started && $0.hasPrompt && !isRead($0) }
        let changed = unread.filter(\.changes.mayHaveChangedFiles)
        var entries: [UnreadTurnEntry] = []
        if let first = changed.first, let last = changed.last {
            entries.append(UnreadTurnEntry(
                turn: UnreadTurn(
                    turnID: first.turnID,
                    numbers: first.displayNumber...max(first.displayNumber, last.displayNumber),
                    changes: summed(changed.map(\.changes)),
                    // The run's latest check, even when its last turn ran none.
                    check: changed.last { $0.lastCheck != nil }?.lastCheck,
                    conversation: conversation
                ),
                arrivedAt: date(first.finishedAt)
            ))
        }
        for turn in unread where !turn.changes.mayHaveChangedFiles {
            entries.append(UnreadTurnEntry(turn: receipt(of: turn), arrivedAt: date(turn.finishedAt)))
        }
        return entries
    }

    /// One turn as a receipt.
    package static func receipt(of turn: TurnSummary) -> UnreadTurn {
        UnreadTurn(
            turnID: turn.turnID,
            numbers: turn.displayNumber...turn.displayNumber,
            changes: turn.changes,
            check: turn.lastCheck,
            conversation: turn.conversation
        )
    }

    /// The latest turn someone prompted that has ended, which the bar at
    /// rest reports.
    package static func latestPrompted(in turns: [TurnSummary]) -> TurnSummary? {
        turns.last { $0.hasPrompt && $0.phase != .started }
    }

    /// The changes of a run of turns. A turn whose changes are still being
    /// taken makes the whole run pending, and one this build cannot read
    /// makes it unknown: a sum without it would understate what changed.
    /// Files are counted per turn, so a file two turns changed counts twice.
    static func summed(_ changes: [ChangeSummary]) -> ChangeSummary {
        var files = 0
        var added = 0
        var removed = 0
        var isUnknown = false
        for change in changes {
            switch change {
            case .pending:
                return .pending
            case let .changed(turnFiles, turnAdded, turnRemoved):
                files += turnFiles
                added += turnAdded
                removed += turnRemoved
            case .unknown:
                isUnknown = true
            case .unchanged, .unavailable:
                continue
            }
        }
        return isUnknown ? .unknown : .changed(files: files, added: added, removed: removed)
    }

    /// The record's time, which the hook writes in RFC 3339 with or without
    /// fractional seconds. A format style rather than a formatter: it is a
    /// value, cheap enough to make on every pass.
    package static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
    }
}
