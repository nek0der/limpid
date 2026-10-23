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

    /// Parts in order, each set off from the one before as the receipt's
    /// facts are.
    private static func joined(_ parts: [[ReceiptRun]], locale: Locale) -> [ReceiptRun] {
        let separator = ReceiptRun(text: AgentStatusText.separator(locale: locale), role: .quiet)
        return parts.filter { !$0.isEmpty }.enumerated().flatMap { index, part in index == 0 ? part : [separator] + part }
    }

    /// The row's second line: "Unviewed · 2 files +94 −2 · ✓ Tests
    /// (filtered) · 3m 05s". A turn that changed nothing, one still
    /// running, and one whose changes are missing say so in place of the
    /// counts; a turn whose changes are still being taken says that beside
    /// its state. In runs: "Unviewed" as the one state the panel colors
    /// (blue is for unviewed turns), the additions and removals in
    /// the diff colors, and a failed check's ✗ in red.
    static func detailRuns(_ row: ChangesPanelModel.Row, locale: Locale) -> [ReceiptRun] {
        var parts: [[ReceiptRun]] = [[ReceiptRun(
            text: status(row.status, locale: locale),
            role: row.status == .unviewed ? .unviewed : .plain
        )]]
        if row.status == .viewed || row.status == .unviewed {
            parts.append(ReceiptText.changeRuns(row.turn.changes, isEmphasized: false, locale: locale))
        }
        if let check = row.turn.lastCheck {
            parts.append([ReceiptRun(text: ReceiptText.check(check, locale: locale), role: check.hasFailed ? .failed : .plain)])
        }
        if let seconds = row.turn.durationSeconds {
            parts.append([ReceiptRun(text: took(seconds, locale: locale), role: .plain)])
        }
        return joined(parts, locale: locale)
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
    /// own lines (`turnDetails`) and its times.
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
        lines += turnDetails(row.turn, locale: locale)
        if let times = times(row.turn, locale: locale, timeZone: timeZone) {
            lines.append(times)
        }
        return lines.joined(separator: "\n")
    }

    /// "Turn of Claude #4": whose turn a row is. "Of", never "by":
    /// a turn's diff is what changed in the worktree during the turn, not
    /// what its conversation wrote.
    static func turnOf(_ conversation: ConversationChoice, locale: Locale) -> String {
        LocalizedStringResource(
            "Turn of \(ConversationText.name(conversation, locale: locale))",
            comment: "Tooltip of a turn's row: which conversation the turn is of; argument: the conversation's name, as in Claude #4"
        ).resolved(in: locale)
    }

    /// The row's badge's words: "#4" beside the "Cl" badge for one of
    /// several Claude conversations, nothing when the kind alone names it.
    static func ordinal(_ conversation: ConversationChoice) -> String? {
        conversation.ordinal.map { "#\($0)" }
    }

    /// What VoiceOver reads for a turn's row, as one list: "Turn 4 of
    /// Claude #4, Unviewed, 2 files +94 −2, took 3m 05s, 10:31". The
    /// badge itself says nothing aloud; the sentence names the
    /// conversation in full, and a turn is "Turn 4", never the "T4" read
    /// letter by letter.
    static func rowSpoken(_ row: ChangesPanelModel.Row, locale: Locale, timeZone: TimeZone = .current) -> String {
        let turn = row.conversation.map { conversation in
            LocalizedStringResource(
                "Turn \(row.turn.displayNumber) of \(ConversationText.name(conversation, locale: locale))",
                comment: "VoiceOver, a turn's row: the turn and its conversation; arguments: the turn's number, the conversation's name"
            ).resolved(in: locale)
        } ?? ReceiptText.spokenTurn(row.turn.displayNumber, locale: locale)
        return AgentStatusText.spokenList(
            [
                turn,
                TurnPromptText.instruction(row.turn.prompt, locale: locale) ?? "",
                AgentStatusText.spoken(detailRuns(row, locale: locale).map(\.text).joined(), locale: locale),
                time(row.turn, locale: locale, timeZone: timeZone) ?? ""
            ],
            locale: locale
        )
    }

    /// "Show 12 viewed turns": the fold's line over the viewed rows at the
    /// top of the list, and "Hide viewed turns" once they are shown.
    static func fold(_ fold: ChangesPanelModel.Fold, isUnfolded: Bool, locale: Locale) -> String {
        if isUnfolded {
            return LocalizedStringResource(
                "Hide viewed turns",
                comment: "Changes panel: folds the viewed turns at the top of the list again"
            )
            .resolved(in: locale)
        }
        return LocalizedStringResource(
            "Show \(fold.count) viewed turns",
            comment: "Changes panel: the viewed turns at the top of the list, folded; argument: how many"
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

    /// What a turn's row keeps in its tooltip: the prompt as recorded
    /// and the check's command in full. The record keeps only the prompt's
    /// first characters; a prompt the harness wrote reads as its kind, as on
    /// the row.
    static func turnDetails(_ turn: TurnSummary, locale: Locale) -> [String] {
        [
            TurnPromptText.instruction(turn.prompt, locale: locale),
            turn.lastCheck?.command,
            largeFilesSkipped(turn, locale: locale)
        ].compactMap { text in
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

    /// The move's words where its whole label does not fit the card at the
    /// panel's narrowest ("Mark All as Viewed up to Here"), still saying it
    /// moves every conversation; `nil` for a move of one line, whose label
    /// always fits.
    static func shortAction(_ action: ChangesPanelModel.RowAction, movesOtherLines: Bool, locale: Locale) -> String? {
        guard movesOtherLines else { return nil }
        let resource = switch action {
        case .markViewedThrough:
            LocalizedStringResource(
                "Mark All as Viewed up to Here",
                comment: "Changes panel: Mark All Conversations as Viewed up to Here, short, where the whole label does not fit"
            )
        case .markUnviewedFrom:
            LocalizedStringResource(
                "Mark All as Unviewed from Here",
                comment: "Changes panel: Mark All Conversations as Unviewed from Here, short, where the whole label does not fit"
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
