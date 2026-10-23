// ReviewStackText.swift
// Limpid — the review tab's files in words: the list's progress, a file's header, and the range's size.

import Foundation

/// The words of the review tab's file list and stacked diff, apart from the
/// rules that choose them.
enum ReviewStackText {
    /// "2 / 5 viewed" (ja 「確認済み 2 / 5」), beside the list's "Files": the
    /// count says what it counts, as the changes panel's "1 unviewed" does.
    static func progress(_ progress: ReviewReadingProgress, locale: Locale) -> String {
        LocalizedStringResource(
            "\(progress.viewed) / \(progress.total) viewed",
            comment: "Review file list: how many of the range's files are checked, of how many"
        ).resolved(in: locale)
    }

    /// `progress` as VoiceOver reads it, "2 of 5 viewed": the slash
    /// would be read as a symbol.
    static func spokenProgress(_ progress: ReviewReadingProgress, locale: Locale) -> String {
        LocalizedStringResource(
            "\(progress.viewed) of \(progress.total) viewed",
            comment: "VoiceOver, review file list: how many of the range's files are checked, of how many"
        ).resolved(in: locale)
    }

    static func mark(_ mark: ReviewFileMark, locale: Locale) -> String {
        let resource = switch mark {
        case .new:
            LocalizedStringResource("New", comment: "Review file header: a file the range added")
        case .changedByBash:
            LocalizedStringResource("Changed by Bash", comment: "Review file header: a file a shell command changed during a turn")
        case .changedOutsideTurns:
            LocalizedStringResource(
                "Changed Outside Turns",
                comment: "Review: a file changed while no turn of the conversation was running"
            )
        }
        return resource.resolved(in: locale)
    }

    /// What a mark means, where its name alone does not say.
    static func markHelp(_ mark: ReviewFileMark, locale: Locale) -> String? {
        switch mark {
        case .new, .changedByBash:
            nil
        case .changedOutsideTurns:
            LocalizedStringResource(
                "Changed while no turn of this conversation was running",
                comment: "Review: tooltip of Changed Outside Turns"
            ).resolved(in: locale)
        }
    }

    /// A checked file's chevron, as VoiceOver reads its value: the words
    /// the file list's headings use (`ReviewFileRail`).
    static func foldState(isFolded: Bool, locale: Locale) -> String {
        (isFolded ? LocalizedStringResource("Collapsed") : LocalizedStringResource("Expanded")).resolved(in: locale)
    }

    /// The checkbox's tooltip: the mark is the reader's own, and the viewed
    /// line moves only with the band's button. The band has no standing
    /// explanation, so this is where it is said.
    static func checkboxHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "Checking a file marks how far you’ve read. The Viewed line moves with “Mark as Viewed” below.",
            comment: "Review: tooltip of a file's checkbox"
        ).resolved(in: locale)
    }

    /// The checkbox's name for VoiceOver, which reads one per file.
    static func checkboxLabel(path: String, locale: Locale) -> String {
        LocalizedStringResource(
            "Mark \(path) as Viewed",
            comment: "Review: a file's checkbox, read by VoiceOver; argument: the file's path"
        )
        .resolved(in: locale)
    }

    /// What the find bar says about where Find looked, when that is not the
    /// whole range: a viewed file folded away (or hidden) is not
    /// searched, and a range larger than the review holds is searched as far
    /// as it is read. "Viewed", the word the checkbox and the list use.
    static func findNote(isLoadedFilesOnly: Bool, skipsViewedFiles: Bool, locale: Locale) -> String? {
        let resource: LocalizedStringResource? = switch (isLoadedFilesOnly, skipsViewedFiles) {
        case (true, true):
            LocalizedStringResource(
                "Searching only the files loaded so far, not the viewed ones: this scope is too large to load at once.",
                comment: "Review find bar: Find searches the files read, less the viewed ones, as the range is too large"
            )
        case (true, false):
            LocalizedStringResource(
                "Searching only the files loaded so far: this scope is too large to load at once.",
                comment: "Review find bar: the range is larger than the review holds, so Find searches the files read"
            )
        case (false, true):
            LocalizedStringResource(
                "Viewed files aren’t searched.",
                comment: "Review find bar: viewed files are folded away and not searched"
            )
        case (false, false):
            nil
        }
        return resource?.resolved(in: locale)
    }

    /// "2 files +94 −2" over the stacked diff, in the order the receipt
    /// and the changes panel write a diff's counts.
    static func summary(files: [ReviewFile], stats: [String: ReviewFileStat], locale: Locale) -> [ReceiptRun] {
        let counted = files.compactMap { stats[$0.id] }.filter { !$0.isBinary }
        let added = counted.reduce(0) { $0 + $1.added }
        let removed = counted.reduce(0) { $0 + $1.removed }
        return ChangesPanelText.diffRuns(files: files.count, added: added, removed: removed, locale: locale)
    }
}
