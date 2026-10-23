// ReceiptText.swift
// Limpid — a turn's receipt in words: its number, what it changed, and its last check.

import Foundation

/// The receipt of one turn or a run of turns: "T7 · 2 files +94 −2 ·
/// ✓ Tests (filtered)". Only the three facts a decision needs; the time,
/// cost, and prompt belong to the turn's row in the changes panel.
enum ReceiptText {
    /// A turn's short name, "T7": the same in every language, as the
    /// changes panel's rows, a receipt, and VoiceOver say it.
    static func turn(_ number: Int) -> String {
        "T\(number)"
    }

    /// "T7", or "T6–T7" for a run of turns.
    static func turns(_ numbers: ClosedRange<Int>, locale: Locale) -> String {
        guard numbers.lowerBound != numbers.upperBound else { return turn(numbers.lowerBound) }
        return LocalizedStringResource(
            "T\(numbers.lowerBound)–T\(numbers.upperBound)",
            comment: "A run of turns, first to last, as in T6–T7"
        ).resolved(in: locale)
    }

    /// A turn as VoiceOver reads it, "Turn 7": the short "T7" is read
    /// letter by letter, as 「ティー なな」 in Japanese.
    static func spokenTurn(_ number: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "Turn \(number)",
            comment: "VoiceOver: one turn by its number, where the screen shows T7"
        ).resolved(in: locale)
    }

    /// "Turn 7", or "Turns 6 to 7" for a run, as VoiceOver reads `turns`.
    static func spokenTurns(_ numbers: ClosedRange<Int>, locale: Locale) -> String {
        guard numbers.lowerBound != numbers.upperBound else { return spokenTurn(numbers.lowerBound, locale: locale) }
        return LocalizedStringResource(
            "Turns \(numbers.lowerBound) to \(numbers.upperBound)",
            comment: "VoiceOver: a run of turns, first to last, where the screen shows T6–T7"
        ).resolved(in: locale)
    }

    /// What the turns changed: "2 files +94 −2", "No file changes" only when the
    /// comparison found nothing, and "Couldn’t get the changes" whenever it
    /// could not be made.
    static func changes(_ changes: ChangeSummary, locale: Locale) -> String {
        let resource = switch changes {
        case let .changed(files, added, removed):
            LocalizedStringResource(
                "\(files) files +\(added) −\(removed)",
                comment: "Receipt: files changed, lines added and removed"
            )
        case .unchanged:
            LocalizedStringResource("No file changes", comment: "Receipt: a turn that changed no files")
        case .pending:
            LocalizedStringResource("Getting the changes…", comment: "Receipt: the turn's changes are still being taken")
        case .unavailable:
            LocalizedStringResource("Couldn’t get the changes", comment: "Receipt: the turn's changes could not be taken")
        case .unknown:
            LocalizedStringResource(
                "Changes this version can’t read",
                comment: "Receipt: a newer Limpid recorded the turn's changes in a form this version does not read"
            )
        }
        return resource.resolved(in: locale)
    }

    /// "✓ Tests (filtered)", "✗ Tests", or "Tests" with no mark when the
    /// exit code was not the check's own. A pass says it passed, never
    /// that the work is right.
    static func check(_ check: CheckSummary, locale: Locale) -> String {
        let label = check.isFiltered
            ? LocalizedStringResource("Tests (filtered)", comment: "Receipt: the last check, run on part of the suite")
            : LocalizedStringResource("Tests", comment: "Receipt: the last check")
        let mark = switch check.exitCode {
        case 0: "✓ "
        case .some: "✗ "
        case nil: ""
        }
        return mark + label.resolved(in: locale)
    }

    /// The whole receipt, as the decision bar, the notification, and the
    /// history show it. An episode no turn record stands for has no number.
    static func receipt(_ turn: UnreadTurn, locale: Locale) -> String {
        AgentStatusText.joined(parts(turn, locale: locale, isSpoken: false), locale: locale)
    }

    /// Returns the receipt's facts in order: the turn's number, what changed,
    /// and the last check. When spoken, the number is said as words ("Turn 7"), not
    /// drawn as the tag ("T7"); the caller joins them for the eye or the ear.
    private static func parts(_ turn: UnreadTurn, locale: Locale, isSpoken: Bool) -> [String] {
        var parts: [String] = []
        if let numbers = turn.numbers {
            parts.append(isSpoken ? spokenTurns(numbers, locale: locale) : turns(numbers, locale: locale))
        }
        parts.append(changes(turn.changes, locale: locale))
        if let check = turn.check {
            parts.append(Self.check(check, locale: locale))
        }
        return parts
    }

    /// A receipt's fact as VoiceOver reads it: "T7" or "T6–T7" (「T6〜T7」)
    /// as `spokenTurns` says it, any other fact as it is. For receipts kept
    /// as text, such as a notification's from before its turn was recorded.
    static func spokenFact(_ fact: String, locale: Locale) -> String {
        guard let match = fact.wholeMatch(of: /T(\d+)(?:[–〜]T(\d+))?/),
              let first = Int(match.1)
        else { return fact }
        let last = match.2.flatMap { Int($0) } ?? first
        guard first <= last else { return fact }
        return spokenTurns(first...last, locale: locale)
    }

    /// `receipt` as VoiceOver reads it: "Turn 7, 2 files +94 −2, ✓ Tests".
    static func spokenReceipt(_ turn: UnreadTurn, locale: Locale) -> String {
        AgentStatusText.spokenList(parts(turn, locale: locale, isSpoken: true), locale: locale)
    }

    // MARK: Runs

    /// The receipt of `turn` as the decision bar draws it, in runs: what
    /// changed, its additions and removals in their colors, and a failed
    /// check in red. `emphasizesChanges` sets what changed apart, as
    /// the bar does on unread turns. The number leads only `includesTurnNumber`;
    /// the unread bar tags it instead.
    static func runs(_ turn: UnreadTurn, includesTurnNumber: Bool, emphasizesChanges: Bool, locale: Locale) -> [ReceiptRun] {
        var parts: [[ReceiptRun]] = []
        if includesTurnNumber, let numbers = turn.numbers {
            parts.append([ReceiptRun(text: turns(numbers, locale: locale), role: .plain)])
        }
        parts.append(changeRuns(turn.changes, isEmphasized: emphasizesChanges, locale: locale))
        if let check = turn.check {
            parts.append([ReceiptRun(text: Self.check(check, locale: locale), role: check.hasFailed ? .failed : .plain)])
        }
        let separator = ReceiptRun(text: AgentStatusText.separator(locale: locale), role: .quiet)
        return parts.enumerated().flatMap { index, part in index == 0 ? part : [separator] + part }
    }

    /// What changed, with "+94" and "−2" as runs of their own, found in the
    /// sentence as the language words it. A count of a thousand or more
    /// may be written with the locale's grouping ("+12,345", "+12.345"), so
    /// it is looked for as the locale writes the number, then bare.
    static func changeRuns(_ summary: ChangeSummary, isEmphasized: Bool, locale: Locale) -> [ReceiptRun] {
        let text = changes(summary, locale: locale)
        let role: ReceiptRun.Role = isEmphasized ? .emphasized : .plain
        guard case let .changed(_, added, removed) = summary else { return [ReceiptRun(text: text, role: role)] }
        return diffRuns(in: text, added: added, removed: removed, isEmphasized: isEmphasized, locale: locale)
    }

    /// `text` with its "+94" and "−2" as runs of their own and the rest in
    /// `isEmphasized`'s role, or `text` whole when it does not hold them in
    /// that order. A count is looked for as `signed` writes it, then bare.
    static func diffRuns(in text: String, added: Int, removed: Int, isEmphasized: Bool, locale: Locale) -> [ReceiptRun] {
        let role: ReceiptRun.Role = isEmphasized ? .emphasized : .plain
        func find(_ sign: String, _ count: Int) -> Range<String.Index>? {
            [signed(count, sign: sign, locale: locale), sign + String(count)]
                .lazy
                .compactMap { text.range(of: $0, options: .backwards) }
                .first
        }
        guard let plus = find("+", added),
              let minus = find("−", removed),
              plus.upperBound <= minus.lowerBound
        else { return [ReceiptRun(text: text, role: role)] }
        return [
            ReceiptRun(text: String(text[..<plus.lowerBound]), role: role),
            ReceiptRun(text: String(text[plus]), role: .added(isEmphasized: isEmphasized)),
            ReceiptRun(text: String(text[plus.upperBound..<minus.lowerBound]), role: role),
            ReceiptRun(text: String(text[minus]), role: .removed(isEmphasized: isEmphasized)),
            ReceiptRun(text: String(text[minus.upperBound...]), role: role)
        ].filter { !$0.text.isEmpty }
    }

    /// "+12,345", "−2": a count of lines with its sign, its figures grouped
    /// as the locale groups them, as the receipt's sentence writes them.
    static func signed(_ count: Int, sign: String, locale: Locale) -> String {
        sign + count.formatted(.number.locale(locale))
    }
}

/// A piece of a line drawn in its own color or weight by
/// `ReceiptRunsText`: the receipt's additions and removals, a failed
/// check, the sentence the decision bar is about, the changes panel's
/// "Unviewed".
struct ReceiptRun: Equatable {
    enum Role: Equatable {
        /// The line's own words, set apart from what follows them: the
        /// decision bar's sentence, the restore strip's question.
        case emphasized
        case plain
        /// A separator, or words that only place the rest (where to
        /// answer).
        case quiet
        case added(isEmphasized: Bool)
        case removed(isEmphasized: Bool)
        /// A check that failed: its ✗ is red.
        case failed
        /// The changes panel's "Unviewed", the one state it draws in the
        /// unread blue.
        case unviewed
    }

    let text: String
    let role: Role
}

extension CheckSummary {
    /// The check's own exit code says it failed: the ✗ the receipt draws
    /// in red. Not an exit code that was another command's.
    var hasFailed: Bool {
        exitCode.map { $0 != 0 } ?? false
    }
}
