// UndoOutcomeText.swift
// Weir — how undoing a restore or a discard fell short, in one set of rules for both.

import Foundation

/// This is what a failed undo says, for the two moves that write through
/// the restore journal. The cases, the refusal's reason, and the files kept
/// aside are read alike for both; only the words differ, and what an
/// unknown end asks the person to check: the whole working tree after a
/// restore, the one file after a discard.
enum UndoOutcomeText {
    /// This is the move being undone. It has two cases rather than the
    /// journal's operation, which also has one for a record a newer bridge
    /// wrote: no undo starts from that, so no wording is needed for it.
    enum Operation {
        case restore
        case discard
    }

    static func message(_ result: RestoreCoordinator.UndoResult, operation: Operation, locale: Locale) -> String {
        switch result {
        case let .refused(refusal):
            guard let reason = RestoreText.refusal(refusal, locale: locale) else {
                return notWritten(operation, locale: locale)
            }
            return refused(operation, reason: reason, locale: locale)
        case let .partial(keptAside):
            return RestoreText.joined(
                [partial(operation, locale: locale)] + [RestoreText.keptAsideSentence(keptAside, locale: locale)].compactMap(\.self),
                locale: locale
            )
        case .canceled:
            return notWritten(operation, locale: locale)
        case .unknown:
            return unknown(operation, locale: locale)
        }
    }

    private static func refused(_ operation: Operation, reason: String, locale: Locale) -> String {
        switch operation {
        case .restore:
            LocalizedStringResource(
                "Couldn’t undo the restore. \(reason)",
                comment: "Restore record: Undo Restore was refused; argument: why"
            ).resolved(in: locale)
        case .discard:
            LocalizedStringResource(
                "Couldn’t undo the discard. \(reason)",
                comment: "Review: Undo Discard was refused; argument: why"
            ).resolved(in: locale)
        }
    }

    private static func partial(_ operation: Operation, locale: Locale) -> String {
        switch operation {
        case .restore:
            LocalizedStringResource(
                "Undid only part of the restore.",
                comment: "Restore record: Undo Restore stopped partway; the record offers the rest"
            ).resolved(in: locale)
        case .discard:
            LocalizedStringResource(
                "Undid only part of the discard.",
                comment: "Review: Undo Discard stopped partway"
            ).resolved(in: locale)
        }
    }

    private static func unknown(_ operation: Operation, locale: Locale) -> String {
        switch operation {
        case .restore:
            LocalizedStringResource(
                "Couldn’t tell how undoing the restore ended. Check the working tree before going on.",
                comment: "Restore record: the journal of Undo Restore could not be read to its end"
            ).resolved(in: locale)
        case .discard:
            LocalizedStringResource(
                "Couldn’t tell how undoing the discard ended. Check the file.",
                comment: "Review: how Undo Discard ended could not be read"
            ).resolved(in: locale)
        }
    }

    private static func notWritten(_ operation: Operation, locale: Locale) -> String {
        switch operation {
        case .restore:
            LocalizedStringResource(
                "Couldn’t undo the restore. No files were changed.",
                comment: "Restore record: Undo Restore wrote nothing, for no reason the person can act on"
            ).resolved(in: locale)
        case .discard:
            LocalizedStringResource(
                "Couldn’t undo the discard. No files were changed.",
                comment: "Review: Undo Discard wrote nothing, for no reason the person can act on"
            ).resolved(in: locale)
        }
    }
}
