// ChangesPanelText.swift
// Limpid — the changes panel in words: the counts, the filter, each turn's row, and the viewed line.

import Foundation

/// The words of the changes panel. The receipt's own facts (what a turn
/// changed, its last check) read as the decision bar reads them
/// (`ReceiptText`); the row adds what the bar leaves out: the prompt, the
/// time, and how long the turn ran.
enum ChangesPanelText {
    /// "14 turns · 10 unviewed": the worktree's turns, every conversation's
    /// together, whatever the filter shows. A line that states counts
    /// rather than names a control, so it is in sentence case. "0
    /// unviewed" stays once every turn is viewed: a count of nothing is
    /// quiet rather than gone, so the head keeps its shape as the
    /// lines move.
    static func summary(turns: Int, unviewed: Int, locale: Locale) -> String {
        let count = LocalizedStringResource(
            "\(turns) turns",
            comment: "A count of turns: the changes panel's head, the turns a setting keeps"
        )
        .resolved(in: locale)
        return AgentStatusText.joined([count, ConversationText.unviewed(unviewed, locale: locale)], locale: locale)
    }

    /// "Unviewed range: 5 files +288 −24", "Includes changes by shell
    /// commands", "1 file changed outside turns": what the worktree's
    /// unviewed range changed, as one comparison from its oldest begin to
    /// the end of the turn that ended last, or "Unviewed range: incomplete
    /// record" where there is none to count, and what the turns do not
    /// account for, marked "(incomplete record)" where some of it
    /// could not be counted, in runs, its additions and removals in the diff
    /// colors. One fact to a line: at the panel's default width two facts
    /// on one line wrapped, cutting one of them where the wrap fell. The
    /// counts read in the receipt's order, as every count of a diff does,
    /// so the same facts never look like different ones.
    static func totalsLines(_ list: ChangesPanelModel.TurnList, locale: Locale) -> [[ReceiptRun]] {
        var parts: [[ReceiptRun]] = []
        // Named as the unviewed range's, since the counts are not the
        // worktree's since its first turn, nor the row's above them.
        let label = ReceiptRun(text: LocalizedStringResource(
            "changes.totalsLabel",
            defaultValue: "Unviewed range: ",
            comment: "Changes panel: what the totals line counts, before its counts, as in Unviewed range: 9 files +412 −61"
        ).resolved(in: locale), role: .plain)
        if list.showsTurnCounts {
            parts.append([label] + diffRuns(files: list.fileCount, added: list.added, removed: list.removed, locale: locale))
        } else if list.isTotalsIncomplete {
            parts.append([label, ReceiptRun(text: LocalizedStringResource(
                "changes.totalsIncomplete",
                defaultValue: "incomplete record",
                comment: "Changes panel: the unviewed range has no fixed comparison to count, as a snapshot at its ends is missing"
            ).resolved(in: locale), role: .plain)])
        }
        if list.hasShellChanges {
            parts.append([ReceiptRun(text: LocalizedStringResource(
                "Includes changes by shell commands",
                comment: "Changes panel: some of the turns' changes came from shell commands"
            ).resolved(in: locale), role: .plain)])
        }
        if let outside = list.pathsOutsideTurns, outside > 0 {
            // A short count says so, as the totals' does: a number alone
            // would read as every file changed outside turns.
            let text = list.isOutsideTurnsIncomplete
                ? LocalizedStringResource(
                    "\(outside) files changed outside turns (incomplete record)",
                    comment: "Changes panel: files changed while no turn ran, where some could not be counted"
                )
                : LocalizedStringResource(
                    "\(outside) files changed outside turns",
                    comment: "Changes panel: files changed while no turn ran"
                )
            parts.append([ReceiptRun(text: text.resolved(in: locale), role: .plain)])
        } else if list.isOutsideTurnsIncomplete {
            parts.append([ReceiptRun(text: LocalizedStringResource(
                "changes.outsideTurnsIncomplete",
                defaultValue: "Changed outside turns: incomplete record",
                comment: "Changes panel: none was counted outside turns, but some could not be, as two agents' turns ended in one second"
            ).resolved(in: locale), role: .plain)])
        }
        return parts
    }

    /// "5 files +288 −24", in the receipt's own words
    /// (`ReceiptText.changes`), or "+288 −24" while the count of files is
    /// not known. The review's summary over its stacked diff reads the same.
    static func diffRuns(files: Int?, added: Int, removed: Int, locale: Locale) -> [ReceiptRun] {
        if let files {
            return ReceiptText.changeRuns(.changed(files: files, added: added, removed: removed), isEmphasized: false, locale: locale)
        }
        return [
            ReceiptRun(text: ReceiptText.signed(added, sign: "+", locale: locale), role: .added(isEmphasized: false)),
            ReceiptRun(text: " ", role: .plain),
            ReceiptRun(text: ReceiptText.signed(removed, sign: "−", locale: locale), role: .removed(isEmphasized: false))
        ]
    }

    /// The card's second line, fact by fact, each in a place of its own so
    /// the facts stand in columns down the list. Whether the turn is viewed
    /// is not among them: the number's pill says it, and the row's sentence
    /// says it aloud.
    struct Facts: Equatable {
        /// How many files the turn changed, drawn beside a document glyph
        /// rather than with the word, so the line keeps to one line at the
        /// panel's narrowest; `nil` where it has no counts.
        let files: Int?
        /// "+94 −2", or the turn's state in words where it has no counts
        /// ("Running", "No file changes").
        let changes: [ReceiptRun]
        /// The checks in the order they ran ("✗✗✓"), a failure's ✗ in red
        /// and a pass of part of the suite quieter than a whole one, led by
        /// "…" when the turn ran more than are shown. Empty for a turn that
        /// ran none.
        let checks: [ReceiptRun]
        /// "84K", "≥84K" when part of the turn could not be read; the card
        /// writes the unit after it.
        let tokens: String?
        /// "11m", the duration to its larger unit; the tooltip has it to
        /// the second.
        let duration: String?

        /// Whether `changes` says the turn's state in words rather than its
        /// counts, which then take the room an empty column leaves.
        var isStatus: Bool {
            files == nil
        }
    }

    /// How many check runs the card shows; earlier ones are "…". Three tell
    /// how the turn got to its last result and leave the changes their room;
    /// the tooltip counts every run.
    static let shownCheckMarks = 3

    static func facts(_ row: ChangesPanelModel.Row, locale: Locale) -> Facts {
        let hasCounts = row.status.hasCounts
        let (files, changes): (Int?, [ReceiptRun]) = switch row.turn.changes {
        case let .changed(files, added, removed) where hasCounts:
            (files, diffRuns(files: nil, added: added, removed: removed, locale: locale))
        case let summary where hasCounts:
            (nil, ReceiptText.changeRuns(summary, isEmphasized: false, locale: locale))
        default:
            (nil, [ReceiptRun(text: status(row.status, locale: locale), role: .plain)])
        }
        return Facts(
            files: files,
            changes: changes,
            checks: checkMarkRuns(row.turn),
            tokens: row.turn.usage.map { tokens($0, locale: locale) },
            duration: row.turn.durationSeconds.map { compactDuration($0, locale: locale) }
        )
    }

    /// "✗✗✓": the turn's last checks, oldest first, led by "…" when it ran
    /// more than are shown, or may have. A record from before the runs were
    /// kept has only its last check, which stands alone. A pass of part of
    /// the suite is a quiet ✓: it says less than a whole one, and the
    /// tooltip names it.
    static func checkMarkRuns(_ turn: TurnSummary) -> [ReceiptRun] {
        let marks = turn.checks.isEmpty
            ? turn.lastCheck.map { [CheckMark(exitCode: $0.exitCode, isFiltered: $0.isFiltered)] } ?? []
            : Array(turn.checks.suffix(shownCheckMarks))
        guard !marks.isEmpty else { return [] }
        let hasEarlier = turn.checkCount > marks.count || turn.areChecksPartial
        let earlier = hasEarlier ? [ReceiptRun(text: "…", role: .quiet)] : []
        return earlier + marks.map { mark in
            switch mark.exitCode {
            case 0: ReceiptRun(text: "✓", role: mark.isFiltered ? .quietMark : .plain)
            case .some: ReceiptRun(text: "✗", role: .failed)
            // The status was not the check's own: it ran, with no result
            // to show.
            case nil: ReceiptRun(text: "–", role: .quiet)
            }
        }
    }

    /// The count a card shows: everything but the cache reads. A turn
    /// rereads the whole conversation from the cache on every request, so
    /// with the reads counted every turn of a long conversation would read
    /// in the millions, and the count would no longer tell a heavy turn
    /// from a light one.
    static func shownTokens(_ usage: TurnUsage) -> Int {
        usage.inputTokens + usage.cacheWriteTokens + usage.outputTokens
    }

    /// "84K", the cache reads left out (`shownTokens`); "≥84K" when the
    /// count is short.
    static func tokens(_ usage: TurnUsage, locale: Locale) -> String {
        let count = compactCount(shownTokens(usage), locale: locale)
        return usage.isPartial ? "≥\(count)" : count
    }

    /// "tok", the unit the card writes after its count of tokens.
    static func tokenUnit(locale: Locale) -> String {
        LocalizedStringResource(
            "tokens.unit",
            defaultValue: "tok",
            comment: "A turn card: the unit after its count of tokens, as in 84K tok; kept short, as the card's column is narrow"
        ).resolved(in: locale)
    }

    /// A count to two figures with "K" or "M" ("84K", "1.2M") in every
    /// language, as the agents' own tools and their status lines write a
    /// count of tokens, so it reads the same here; one under a thousand
    /// whole ("999"), which two figures would round up to "1K".
    static func compactCount(_ count: Int, locale: Locale) -> String {
        guard count >= 1000 else { return exactCount(count, locale: locale) }
        // Halves round up, as people round: 125,000 is "130K", not the
        // "120K" rounding to even gives.
        return count.formatted(
            .number.notation(.compactName).precision(.significantDigits(1...2)).rounded(rule: .toNearestOrAwayFromZero)
                .locale(tokenUnitsLocale)
        )
    }

    /// The locale whose short counts name a thousand "K" and a million "M".
    private static let tokenUnitsLocale = Locale(identifier: "en")

    private static func exactCount(_ count: Int, locale: Locale) -> String {
        count.formatted(.number.locale(locale))
    }

    /// "84,123 tokens", or "At least 84,123 tokens" when part of the turn
    /// could not be read: the tooltip's count, exact, and VoiceOver's,
    /// short ("At least 84K tokens"), never the "≥" a voice reads as a
    /// symbol.
    static func tokenTotal(_ usage: TurnUsage, isExact: Bool, locale: Locale) -> String {
        let shown = shownTokens(usage)
        let count = isExact ? exactCount(shown, locale: locale) : compactCount(shown, locale: locale)
        let resource = usage.isPartial
            ? LocalizedStringResource(
                "tokens.atLeast",
                defaultValue: "At least \(count) tokens",
                comment: "A turn's tokens, part of the turn unread so it used more; argument: the count, as in 84,123 or 84K"
            )
            : LocalizedStringResource(
                "tokens.total",
                defaultValue: "\(count) tokens",
                comment: "A turn's tokens, the cache reads left out; argument: the count, as in 84,123 or 84K"
            )
        return resource.resolved(in: locale)
    }

    /// The tooltip's lines on what the turn used: its exact count, what it
    /// is made of, the cache reads left out of it, and that the count is
    /// short where it is.
    static func usageDetails(_ usage: TurnUsage, locale: Locale) -> [String] {
        let count = { exactCount($0, locale: locale) }
        let input = count(usage.inputTokens)
        let written = count(usage.cacheWriteTokens)
        let output = count(usage.outputTokens)
        var lines = [
            tokenTotal(usage, isExact: true, locale: locale),
            LocalizedStringResource(
                "tokens.breakdown",
                defaultValue: "Input \(input) · Cache writes \(written) · Output \(output)",
                comment: "Tooltip of a turn: what its token count is made of; arguments: fresh input, cache writes, output, as counts"
            ).resolved(in: locale)
        ]
        if usage.cacheReadTokens > 0 {
            lines.append(LocalizedStringResource(
                "tokens.cacheReads",
                defaultValue: "Not counted: \(count(usage.cacheReadTokens)) read from the cache",
                comment: "Tooltip of a turn: the input read from the prompt cache, left out of its token count; argument: a count"
            ).resolved(in: locale))
        }
        if usage.isPartial {
            lines.append(LocalizedStringResource(
                "tokens.partial",
                defaultValue: "Part of the turn could not be read, so the count may be short",
                comment: "Tooltip of a turn: its token count may be lower than what it used"
            ).resolved(in: locale))
        }
        return lines
    }

    /// The tooltip's lines on the turn's checks: "Ran tests 3 times · 2
    /// failed" for a turn that ran more than one ("at least" where the
    /// count may be short), the last check as the receipt says it ("Latest:
    /// ✓ Tests (filtered, after 2 failures)", the one check alone with no
    /// "Latest:"), and its command in full.
    static func checkDetails(_ turn: TurnSummary, locale: Locale) -> [String] {
        let receipt = turn.lastCheck.map { ReceiptText.check($0, locale: locale) }
        // A count of one says no more than the card's one mark; a count of
        // none, partial or not, has nothing to say.
        guard turn.checkCount > 1 || (turn.areChecksPartial && turn.checkCount > 0) else {
            return [receipt, turn.lastCheck?.command].compactMap(\.self)
        }
        let runs = turn.areChecksPartial
            ? LocalizedStringResource(
                "Ran tests at least \(turn.checkCount) times",
                comment: "Tooltip of a turn: how many checks it ran, of which some were not read; argument: how many were"
            )
            : LocalizedStringResource(
                "Ran tests \(turn.checkCount) times",
                comment: "Tooltip of a turn: how many checks it ran; argument: how many"
            )
        let count = turn.failureCount > 0
            ? AgentStatusText.joined([runs.resolved(in: locale), LocalizedStringResource(
                "\(turn.failureCount) failed",
                comment: "Tooltip of a turn: how many of its checks failed, after how many it ran; argument: how many"
            ).resolved(in: locale)], locale: locale)
            : runs.resolved(in: locale)
        let latest = receipt.map { receipt in
            LocalizedStringResource(
                "Latest: \(receipt)",
                comment: "Tooltip of a turn: its last check, after how many it ran; argument: the check as a receipt says it"
            ).resolved(in: locale)
        }
        return [count, latest, turn.lastCheck?.command].compactMap(\.self)
    }

    static func status(_ status: ChangesPanelModel.Status, locale: Locale) -> String {
        let resource = switch status {
        case .viewed: LocalizedStringResource("Viewed")
        case .unviewed: LocalizedStringResource("Unviewed", comment: "Changes panel: a turn below the viewed line")
        case .running: LocalizedStringResource("Running")
        case .answerOnly: LocalizedStringResource("No file changes", comment: "Receipt: a turn that changed no files")
        case .changesUnavailable:
            LocalizedStringResource("Couldn’t get the changes", comment: "Receipt: the turn's changes could not be taken")
        case .incompleteRecord: LocalizedStringResource("Incomplete record")
        case .restored: LocalizedStringResource("Restored", comment: "Changes panel: a turn whose changes a restore took back")
        }
        return resource.resolved(in: locale)
    }

    /// How long the turn ran, to the second, in its two largest units:
    /// "3m 05s", 「3 分 05 秒」. The smaller unit takes two figures, as
    /// a clock writes it, so the rows' durations line up by their units.
    static func duration(_ seconds: Int, locale: Locale) -> String {
        let total = max(0, seconds)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        if hours > 0 {
            return LocalizedStringResource(
                "duration.hoursMinutes",
                defaultValue: "\(hours)h \(twoFigures(minutes))m",
                comment: "How long a turn ran, over an hour; arguments: the hours, the minutes in two figures"
            ).resolved(in: locale)
        }
        if minutes > 0 {
            return LocalizedStringResource(
                "duration.minutesSeconds",
                defaultValue: "\(minutes)m \(twoFigures(rest))s",
                comment: "How long a turn ran, over a minute; arguments: the minutes, the seconds in two figures"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "duration.seconds",
            defaultValue: "\(rest)s",
            comment: "How long a turn ran, under a minute; argument: the seconds"
        ).resolved(in: locale)
    }

    /// The duration as the row says it: "took 3m 05s", 「所要 3 分 05 秒」.
    /// A bare "10s" beside the other facts read as ten seconds ago.
    static func took(_ seconds: Int, locale: Locale) -> String {
        let duration = duration(seconds, locale: locale)
        return LocalizedStringResource(
            "took \(duration)",
            comment: "How long a turn ran, in a turn's row and tooltip; the argument is the duration, as in 3m 05s"
        ).resolved(in: locale)
    }

    /// "Took 3m 05s", 「所要 3 分 05 秒」: the duration as a tooltip's line
    /// of its own starts it.
    static func tookLine(_ seconds: Int, locale: Locale) -> String {
        let duration = duration(seconds, locale: locale)
        return LocalizedStringResource(
            "Took \(duration)",
            comment: "Tooltip of a turn: how long it ran, as a line of its own; the argument is the duration, as in 3m 05s"
        ).resolved(in: locale)
    }

    /// How long the turn ran, in one unit, as the card's column says it:
    /// "40s", "11m", "65m", "2h"; the tooltip has it to the second.
    static func compactDuration(_ seconds: Int, locale: Locale) -> String {
        let total = max(0, seconds)
        // Minutes up to a hundred, so the column keeps to one short figure:
        // "65m" where "1h 05m" took twice the room. Each unit is whole and
        // cut down, as a clock counts, so no unit reads more than ran.
        if total >= 100 * 60 {
            return CompactTimeText.hours(total / 3600, locale: locale)
        }
        if total >= 60 {
            return CompactTimeText.minutes(total / 60, locale: locale)
        }
        return CompactTimeText.seconds(total, locale: locale)
    }

    private static func twoFigures(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    /// When the turn started, as a clock time: "12:41". The row's time is
    /// its start, which is what the timeline orders by; its end is in
    /// the tooltip (`times`).
    static func time(_ turn: TurnSummary, locale: Locale, timeZone: TimeZone = .current) -> String? {
        guard let date = UnreadTurnRules.date(turn.startedAt) else { return nil }
        return ConversationText.clock(date, locale: locale, timeZone: timeZone)
    }

    /// "Started 10:31 · Ended 10:34": the row's tooltip's line of times,
    /// so a turn that ran beside another reads as the span it was. Only
    /// the start for a turn still running or whose end was not recorded.
    /// `nil` when neither time can be read.
    static func times(_ turn: TurnSummary, locale: Locale, timeZone: TimeZone = .current) -> String? {
        guard let started = UnreadTurnRules.date(turn.startedAt) else { return nil }
        let start = LocalizedStringResource(
            "Started \(ConversationText.clock(started, locale: locale, timeZone: timeZone))",
            comment: "Tooltip of a turn's row: when the turn started; argument: a clock time, as in 10:31"
        ).resolved(in: locale)
        guard let finished = UnreadTurnRules.date(turn.finishedAt) else { return start }
        let end = LocalizedStringResource(
            "Ended \(ConversationText.clock(finished, locale: locale, timeZone: timeZone))",
            comment: "Tooltip of a turn's row: when the turn ended; argument: a clock time, as in 10:34"
        ).resolved(in: locale)
        return AgentStatusText.joined([start, end], locale: locale)
    }

    /// The row's tooltip: what it opens, whose turn it is, then the turn's
    /// own lines in the card's order (`turnDetails`) and its times.
    static func help(_ row: ChangesPanelModel.Row, locale: Locale, timeZone: TimeZone = .current) -> String {
        var lines: [String] = []
        if row.isSelectable {
            lines.append(LocalizedStringResource(
                "Open T\(row.turn.displayNumber) in Review",
                comment: "Changes panel: a turn's row opens it in the review"
            ).resolved(in: locale))
        }
        if let conversation = row.conversation {
            lines.append(turnOf(conversation, locale: locale))
        }
        lines += turnDetails(row.turn, showsChanges: row.status.hasCounts, locale: locale)
        if let times = times(row.turn, locale: locale, timeZone: timeZone) {
            lines.append(times)
        }
        // Last and set apart, as the card's own third line is: the rest of
        // a reply the card cut at two lines.
        if let reply = row.turn.reply {
            lines += ["", TurnReplyText.labeled(reply, locale: locale)]
        }
        return lines.joined(separator: "\n")
    }

    /// "Turn of Claude #4": whose turn a row is. "Of", never "by":
    /// a turn's diff is what changed in the worktree during the turn, not
    /// what its conversation wrote.
    static func turnOf(_ conversation: ConversationChoice, locale: Locale) -> String {
        LocalizedStringResource(
            "Turn of \(ConversationText.name(conversation, locale: locale))",
            // swiftlint:disable:next line_length
            comment: "Tooltip of a turn's row: which conversation the turn is of; argument: the conversation's name, as in Claude #4 or Fix tests"
        ).resolved(in: locale)
    }

    /// What VoiceOver reads for a turn's row, as one list: "Turn 4 of
    /// Claude #4, Unviewed, 2 files +94 −2, ✓ Tests (after 2 failures),
    /// 84K tokens, took 3m 05s, 10:31". The
    /// badge itself says nothing aloud; the sentence names the
    /// conversation in full, with its kind before a title
    /// (`ConversationText.spokenName`), and a turn is "Turn 4", never the
    /// "T4" read letter by letter.
    static func rowSpoken(_ row: ChangesPanelModel.Row, locale: Locale, timeZone: TimeZone = .current) -> String {
        let turn = row.conversation.map { conversation in
            LocalizedStringResource(
                "Turn \(row.turn.displayNumber) of \(ConversationText.spokenName(conversation, locale: locale))",
                comment: "VoiceOver, a turn's row: the turn and its conversation; arguments: the turn's number, the conversation's name"
            ).resolved(in: locale)
        } ?? ReceiptText.spokenTurn(row.turn.displayNumber, locale: locale)
        let changes = row.status.hasCounts
            ? ReceiptText.changeRuns(row.turn.changes, isEmphasized: false, locale: locale).map(\.text).joined()
            : nil
        return AgentStatusText.spokenList(
            [
                turn,
                TurnPromptText.instruction(row.turn.prompt, locale: locale) ?? "",
                // The card shows the state only in its number's pill, so
                // the sentence says it in words.
                status(row.status, locale: locale),
                changes ?? "",
                row.turn.lastCheck.map { ReceiptText.check($0, locale: locale) } ?? "",
                row.turn.usage.map { tokenTotal($0, isExact: false, locale: locale) } ?? "",
                row.turn.durationSeconds.map { took($0, locale: locale) } ?? "",
                time(row.turn, locale: locale, timeZone: timeZone) ?? "",
                row.turn.reply.map { TurnReplyText.labeled($0, locale: locale) } ?? ""
            ],
            locale: locale
        )
    }

    /// "Show 12 earlier viewed turns": the fold's line over the viewed rows
    /// at the top of the list. Once they are shown the line is gone, so it
    /// has no other words.
    static func fold(_ fold: ChangesPanelModel.Fold, locale: Locale) -> String {
        LocalizedStringResource(
            "Show \(fold.count) earlier viewed turns",
            comment: "Changes panel: the viewed turns at the top of the list, folded above this line; argument: how many"
        ).resolved(in: locale)
    }

    /// The tooltip of a row's move on the worktree's timeline where it
    /// reaches the other conversations' lines too, the filter's
    /// hidden ones among them.
    static func moveAcrossHelp(_ action: ChangesPanelModel.RowAction, locale: Locale) -> String {
        let resource = switch action {
        case .markViewedThrough:
            LocalizedStringResource(
                "Also marks the other conversations’ turns that ended by the time this one did as viewed",
                comment: "Changes panel: tooltip of Mark All Conversations as Viewed up to Here, which moves other conversations' lines"
            )
        case .markUnviewedFrom:
            LocalizedStringResource(
                "Also marks the other conversations’ turns from this point on as unviewed",
                comment: "Changes panel: tooltip of Mark All Conversations as Unviewed from Here, which moves other conversations' lines"
            )
        }
        return resource.resolved(in: locale)
    }

    /// The head's button: the worktree's unviewed turns in the review,
    /// every conversation's as one comparison. "Review All Unviewed"
    /// in a worktree of two or more conversations, where the decision
    /// bar's "Review Unviewed" opens its own conversation's alone: one name
    /// for two different reads would tell the person neither. With one
    /// conversation the two read the same turns, and share the name.
    static func reviewUnviewed(isAcrossConversations: Bool, locale: Locale) -> String {
        let resource = isAcrossConversations
            ? LocalizedStringResource(
                "Review All Unviewed",
                comment: "Changes panel: opens every conversation's unviewed turns in the worktree in review, as one comparison"
            )
            : LocalizedStringResource("Review Unviewed", comment: "Changes panel and decision bar: opens the unviewed turns in review")
        return resource.resolved(in: locale)
    }

    static func reviewUnviewedHelp(locale: Locale) -> String {
        LocalizedStringResource(
            "Opens the worktree’s unviewed turns in review",
            comment: "Changes panel: tooltip of Review Unviewed, which opens every conversation's unviewed turns as one comparison"
        ).resolved(in: locale)
    }

    // MARK: - The filter

    /// "Conversation", the filter's heading.
    static func filterHeading(locale: Locale) -> String {
        LocalizedStringResource(
            "changes.filterHeading",
            defaultValue: "Conversation",
            comment: "Changes panel: the heading of the filter that narrows the timeline to one conversation"
        )
        .resolved(in: locale)
    }

    /// "All", the filter's default: every conversation's turns.
    static func filterAll(locale: Locale) -> String {
        LocalizedStringResource(
            "changes.filterAll",
            defaultValue: "All",
            comment: "Changes panel: the filter's entry that shows every conversation's turns"
        )
        .resolved(in: locale)
    }

    /// The filter's label: the conversation shown, or "All".
    static func filterLabel(_ filter: ConversationKey?, among conversations: [ConversationChoice], locale: Locale) -> String {
        conversations.first { $0.conversation == filter }.map { ConversationText.name($0, locale: locale) } ?? filterAll(locale: locale)
    }

    /// The filter's label as VoiceOver says it: a titled conversation with
    /// its agent (`ConversationText.spokenName`), as its menu item says it,
    /// so the trigger reads as the item it came from.
    static func filterSpokenLabel(_ filter: ConversationKey?, among conversations: [ConversationChoice], locale: Locale) -> String {
        conversations.first { $0.conversation == filter }
            .map { ConversationText.spokenName($0, locale: locale) } ?? filterAll(locale: locale)
    }

    /// The filter's tooltip: what the conversation shown is doing, or what
    /// "All" shows.
    static func filterHelp(_ filter: ConversationKey?, among conversations: [ConversationChoice], locale: Locale) -> String {
        guard let shown = conversations.first(where: { $0.conversation == filter }) else {
            return LocalizedStringResource(
                "Shows every conversation’s turns",
                comment: "Changes panel: tooltip of the filter while it shows every conversation"
            ).resolved(in: locale)
        }
        return ConversationText.help(shown, locale: locale)
    }

    /// What a turn's row keeps in its tooltip, in the card's order: the
    /// prompt as recorded, what it changed in full (the card cuts it short
    /// where the panel is narrow) when `showsChanges`, its checks
    /// (`checkDetails`), what it used (`usageDetails`), and how long it ran.
    /// The record keeps only the prompt's first characters; a prompt the
    /// harness wrote reads as its kind, as on the row.
    static func turnDetails(_ turn: TurnSummary, showsChanges: Bool, locale: Locale) -> [String] {
        var lines: [String?] = [
            TurnPromptText.instruction(turn.prompt, locale: locale),
            showsChanges ? ReceiptText.changes(turn.changes, locale: locale) : nil,
            largeFilesSkipped(turn, locale: locale)
        ]
        lines += checkDetails(turn, locale: locale)
        lines += turn.usage.map { usageDetails($0, locale: locale) } ?? []
        lines.append(turn.durationSeconds.map { tookLine($0, locale: locale) })
        return lines.compactMap { text in
            text.flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    /// "Skipped 2 large files": untracked files over the size limit that
    /// neither snapshot holds, so the turn's counts may be short.
    /// `nil` for a turn that skipped none.
    static func largeFilesSkipped(_ turn: TurnSummary, locale: Locale) -> String? {
        guard turn.largeFilesSkipped > 0 else { return nil }
        return LocalizedStringResource(
            "Skipped \(turn.largeFilesSkipped) large files",
            comment: "Tooltip of a turn: untracked files over the size limit the turn's record left out; argument: how many"
        ).resolved(in: locale)
    }

    /// "Viewed up to here", the line between the viewed turns and the rest.
    static func line(locale: Locale) -> String {
        LocalizedStringResource("Viewed up to here", comment: "Changes panel: the viewed line").resolved(in: locale)
    }

    /// The card's moves, in the order its glyphs stand: the viewed line's,
    /// then the restore.
    static func moves(_ row: ChangesPanelModel.Row, locale: Locale) -> [TurnCardMove] {
        var moves: [TurnCardMove] = []
        if let action = row.action {
            // On the timeline the move may reach the other conversations'
            // lines too, which its title says, and its tooltip how far.
            moves.append(TurnCardMove(
                kind: .line(action),
                title: Self.action(action, movesOtherLines: row.movesOtherLines, locale: locale),
                detail: row.movesOtherLines ? moveAcrossHelp(action, locale: locale) : nil,
                blocker: nil
            ))
        }
        if row.offersRestore {
            let blocker = row.restoreBlocker.map { RestoreText.blocker($0, locale: locale) }
            moves.append(TurnCardMove(kind: .restore, title: RestoreText.entry(locale: locale), detail: nil, blocker: blocker))
        }
        return moves
    }

    /// "Unmark as Viewed", on the line below the latest turn.
    static func unmarkViewed(locale: Locale) -> String {
        LocalizedStringResource("Unmark as Viewed", comment: "Changes panel: takes back the move of the viewed line below the latest turn")
            .resolved(in: locale)
    }

    /// A row's move of the line. "Mark All Conversations as Viewed up to
    /// Here" where it moves other conversations' lines too
    /// (`Row.movesOtherLines`): the button says what it does to rows the
    /// filter may hide, not the tooltip alone. The short form
    /// otherwise.
    static func action(_ action: ChangesPanelModel.RowAction, movesOtherLines: Bool = false, locale: Locale) -> String {
        let resource = switch (action, movesOtherLines) {
        case (.markViewedThrough, false):
            LocalizedStringResource("Mark as Viewed up to Here", comment: "Changes panel: moves the viewed line below this turn")
        case (.markUnviewedFrom, false):
            LocalizedStringResource("Mark as Unviewed from Here", comment: "Changes panel: moves the viewed line above this turn")
        case (.markViewedThrough, true):
            LocalizedStringResource(
                "Mark All Conversations as Viewed up to Here",
                comment: "Changes panel: moves every conversation's viewed line up to this turn's end, hidden ones too"
            )
        case (.markUnviewedFrom, true):
            LocalizedStringResource(
                "Mark All Conversations as Unviewed from Here",
                comment: "Changes panel: moves every conversation's viewed line back above this row, hidden ones too"
            )
        }
        return resource.resolved(in: locale)
    }

    /// Why the panel lists no turns: its empty state, `nil` while it
    /// lists them or is still asking Git.
    static func empty(_ content: ChangesPanelModel.Content) -> EmptyState? {
        switch content {
        case .noWorktree:
            .noWorktreeSelected
        case .notGitRepository:
            .notGitRepository
        case .waitingForRepository:
            nil
        case .repositoryUnavailable:
            .changesUnavailable
        case let .turns(list):
            list.rows.isEmpty ? .noTurns : nil
        }
    }

    /// The rail button's tooltip: "Changes (⌥⌘I) · 3 unviewed", then
    /// each conversation with turns to read on a line of its own ("Claude
    /// #1 · 1 unviewed"), so the total reads as the panel's count and the
    /// rest rather than a count the panel contradicts. No lines while one
    /// conversation has them all, whose count is the total.
    static func railHelp(shortcut: String?, unviewed: Int, agents: [ConversationChoice], locale: Locale) -> String {
        let name = ShortcutHelpText.make(name: "Changes", shortcut: shortcut, locale: locale)
        guard unviewed > 0 else { return name }
        let head = AgentStatusText.joined([name, ConversationText.unviewed(unviewed, locale: locale)], locale: locale)
        let lines = agents.map { choice in
            AgentStatusText.joined(
                [ConversationText.name(choice, locale: locale), ConversationText.unviewed(choice.unviewedCount, locale: locale)],
                locale: locale
            )
        }
        return ([head] + lines).joined(separator: "\n")
    }

    /// The session header's chip while the sidebar is folded for the panel.
    static func sidebarFolded(locale: Locale) -> String {
        LocalizedStringResource(
            "Sidebar hidden to make room for Changes",
            comment: "Worktree header: the sidebar is folded while the changes panel needs its width"
        ).resolved(in: locale)
    }

    /// The decision bar's receipt tooltip: what the bar leaves to the
    /// panel's rows, each turn's prompt as its row shows it
    /// (`TurnPromptText`) and how long it ran, and the command of the check
    /// the bar shows, in full. `nil` for an episode
    /// no turn record stands for. The turns are the receipt's own: a run of
    /// turns that changed files leaves out an answer between them, which is
    /// a receipt of its own.
    static func receiptHelp(_ unread: UnreadTurn, history: [ConversationKey: [TurnSummary]], locale: Locale) -> String? {
        guard let conversation = unread.conversation, let numbers = unread.numbers else { return nil }
        let turns = (history[conversation] ?? [])
            .filter { turn in
                numbers.contains(turn.displayNumber) && turn.hasPrompt
                    && (!unread.mayHaveChangedFiles || turn.changes.mayHaveChangedFiles)
            }
            .sorted { $0.displayNumber < $1.displayNumber }
        var lines = turns.map { turn in
            AgentStatusText.joined(
                [
                    "T\(turn.displayNumber)",
                    TurnPromptText.instruction(turn.prompt, locale: locale) ?? "",
                    turn.durationSeconds.map { took($0, locale: locale) } ?? "",
                    largeFilesSkipped(turn, locale: locale) ?? ""
                ],
                locale: locale
            )
        }
        if let command = unread.check?.command, !command.isEmpty {
            lines.append(command)
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

/// One of a turn card's moves (`ChangesPanelText.moves`), as its glyphs,
/// its context menu, and its VoiceOver actions all offer it, so the three
/// never disagree.
struct TurnCardMove: Equatable, Identifiable {
    enum Kind: Hashable {
        /// The viewed line's move (`ChangesPanelModel.RowAction`).
        case line(ChangesPanelModel.RowAction)
        /// "Restore Code to Before This Turn…".
        case restore
    }

    let kind: Kind
    let title: String
    /// How far a move of the line reaches beyond this row's conversation.
    let detail: String?
    /// Why the restore cannot run now, `nil` while it can.
    let blocker: String?

    var id: Kind {
        kind
    }

    var isEnabled: Bool {
        blocker == nil
    }

    /// What the tooltip and VoiceOver's hint add to the title: how far the
    /// move reaches, or why it cannot run now.
    var note: String? {
        detail ?? blocker
    }

    /// The glyph's tooltip: the title, then what it adds.
    var help: String {
        note.map { "\(title)\n\($0)" } ?? title
    }
}

// MARK: - The grouping

extension ChangesPanelText {
    /// A segment of the head's choice of how the turns are listed.
    static func grouping(_ grouping: ChangesPanelGrouping, locale: Locale) -> String {
        let resource = switch grouping {
        case .timeline:
            LocalizedStringResource(
                "changes.groupingTimeline",
                defaultValue: "Timeline",
                comment: "Changes panel: the segment that lists every conversation's turns as one timeline"
            )
        case .byConversation:
            LocalizedStringResource(
                "changes.groupingByConversation",
                defaultValue: "By Conversation",
                comment: "Changes panel: the segment that lists the turns in a section per conversation"
            )
        }
        return resource.resolved(in: locale)
    }

    /// What VoiceOver calls the choice between the two groupings.
    static func groupingLabel(locale: Locale) -> String {
        LocalizedStringResource(
            "changes.groupingLabel",
            defaultValue: "Arrange Turns",
            comment: "Changes panel: VoiceOver's name for the choice between a timeline and a section per conversation"
        )
        .resolved(in: locale)
    }
}
