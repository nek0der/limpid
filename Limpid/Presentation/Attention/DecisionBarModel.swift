// DecisionBarModel.swift
// Limpid — an agent pane's decision bar in words.

import Foundation

/// What the bar under an agent's pane reads: a short tag for what it is
/// on, the sentence, where to answer, and its place among the pane's items.
/// The time left is drawn live from `heldUntil`, so it is not in here.
struct DecisionBarModel: Equatable {
    /// The bar's color. The tag and the words carry the same meaning.
    enum Tone: Equatable {
        case muted
        case waiting
        case stopped
        case unread
        case done
    }

    let content: DecisionBarContent
    /// "Approval", "Question", "Stopped", "Unread"; none at rest, nor
    /// right after an item was handled, where the row leads with a muted
    /// checkmark instead and the sentence says what happened. The check
    /// stays muted rather than green: green is never a state's color here.
    let tag: String?
    /// `tag` as VoiceOver reads it: "Turn 7" where the tag shows "T7".
    let spokenTag: String?
    let tone: Tone
    /// The whole sentence, as the bar's tooltip and receipt join it.
    let text: String
    /// `text` as VoiceOver reads it: its facts as a list, not set off by
    /// " · ", and a turn by its word rather than "T7".
    let spokenText: String
    /// `text` in the pieces the bar draws in their own weight or color: the
    /// sentence it is about, set apart; a receipt's additions, removals,
    /// and failed check.
    let runs: [ReceiptRun]
    /// Where the request is answered, for an approval or a question. The
    /// row keeps it whole and cuts the sentence instead: it is what the
    /// person has to do.
    let instruction: String?
    /// "1 / 2 · Approval also pending".
    let countText: String?
    /// What VoiceOver reads for the count ("Needs Attention in this pane:
    /// 1 / 2"), which on its own would not say what it counts.
    let countSpokenText: String?
    /// The deadline of a request Limpid still holds, for "8:42 left".
    let heldUntil: ServiceDeadline?
    /// What a usage limit stop offers in place of resuming while the limit
    /// holds; `nil` on any other bar.
    let resetNotice: UsageLimitResetNotice?

    /// The button ⌘⏎ presses: "Mark as Viewed" on an unread turn that
    /// may have changed files, "Resume Same Conversation" on a stop that can
    /// be resumed, "Notify When It Resets" on a stop at a usage limit
    /// that resets later, which resuming would only meet again, and "Close
    /// All Tabs" on a worktree that is gone. A turn known
    /// to have changed none is read by opening its pane, so it offers
    /// nothing to mark.
    var primaryAction: PrimaryAction? {
        guard let itemID = content.itemID else { return nil }
        if case .stopped(.worktreeMissing, _) = content.body {
            return .closeAllTabs(itemID)
        }
        if case .stopped = content.body, let resetNotice {
            return resetNotice == .offered ? .notifyAtReset(itemID) : nil
        }
        switch content.body {
        case let .unread(turn) where turn.mayHaveChangedFiles:
            return .markReviewed(itemID, throughTurn: turn.numbers?.upperBound)
        case .stopped(_, .available), .stopped(_, .failed):
            return .resume(itemID)
        default:
            return nil
        }
    }

    /// The agent's words in full for a wait at its prompt, which the
    /// sentence cuts short or, for an approval, leaves out ("Write:
    /// /Users/…/notes.txt"); `nil` on any other bar.
    var textHelp: String? {
        guard case let .prompt(_, wait) = content.body else { return nil }
        return wait.detail
    }

    /// Whether the sentence is cut in its middle rather than at its end: a
    /// prompt's own words often end in the file they are about.
    /// An approval's sentence is the bar's own, cut at its end like any.
    var cutsTextInMiddle: Bool {
        if case .prompt(_, .unclassified) = content.body {
            true
        } else {
            false
        }
    }

    /// Where to answer in the fewest words ("Answer in terminal"), for a
    /// bar too narrow for `instruction` beside the sentence's least; the
    /// whole instruction where it has no shorter form.
    let shortInstruction: String?

    private static func shortInstruction(_ instruction: String?, for body: DecisionBarContent.Body, locale: Locale) -> String? {
        guard let instruction else { return nil }
        let short: LocalizedStringResource? = switch body {
        case .prompt, .approval(_, _, .terminal), .question(_, .terminal):
            LocalizedStringResource("Answer in terminal")
        // Still says the time ran out, which is why the terminal answers it.
        case .approval(_, _, .terminalAfterTimeout), .question(_, .terminalAfterTimeout):
            LocalizedStringResource(
                "Timed out — answer in terminal",
                comment: "Decision bar, short of room: Limpid's time for the request ran out, so the terminal answers it"
            )
        default:
            nil
        }
        return short?.resolved(in: locale) ?? instruction
    }

    /// The stop the bar shows, for its ⋯ menu: "Show Partial Changes" and
    /// "Start New Conversation". Not while its resume is on its way,
    /// nor for a worktree that is gone, which has no conversation of its
    /// own and no folder to start one in.
    var stopItem: AttentionItemID? {
        guard case let .stopped(reason, _) = content.body, reason != .worktreeMissing else { return nil }
        return content.itemID
    }

    /// Whether the bar offers "Review Unviewed": beside "Mark as Viewed",
    /// on the same unread turns, to read them before marking them.
    var offersReview: Bool {
        guard case let .unread(turn) = content.body else { return false }
        return turn.mayHaveChangedFiles
    }

    /// The conversation the bar's unread turns are in, which "Review
    /// Unviewed" reads, rather than finding the pane's agent again.
    var reviewConversation: ConversationKey? {
        guard case let .unread(turn) = content.body else { return nil }
        return turn.conversation
    }

    /// Whether nothing waits on the person, nothing was just done, and the
    /// agent is not at work: the bar only says what was done last, and a
    /// restore's record may take its place. What a working agent is
    /// doing stays: the record is no news to it, and its turn ends the
    /// record anyway.
    var isAtRest: Bool {
        switch content.body {
        case .lastTurn:
            true
        case let .summary(fact):
            switch fact {
            case .running, .compacting: false
            default: true
            }
        default:
            false
        }
    }

    /// What the "Done" line's Undo takes back, when it offers one.
    var undo: ViewedLineUndo? {
        guard case let .done(.markedViewed(undo), _) = content.body else { return nil }
        return undo
    }

    /// The unread turns' ⋯ entry: restoring to the start of the
    /// first of them, named by number when several are shown, as "this
    /// turn" would not say which. Only for recorded turns that may have
    /// changed files.
    func restoreEntry(locale: Locale) -> RestoreEntry? {
        guard case let .unread(turn) = content.body, turn.mayHaveChangedFiles, turn.conversation != nil,
              let numbers = turn.numbers
        else { return nil }
        let named = numbers.count > 1 ? numbers.lowerBound : nil
        return RestoreEntry(turnID: turn.turnID, turnNumber: named, title: RestoreText.entry(turnNumber: named, locale: locale))
    }

    /// The ⋯ entry that restores to before a turn: the turn, and what the
    /// entry says.
    struct RestoreEntry: Equatable {
        let turnID: TurnID
        /// The number the entry names its turn by, where "this turn" would
        /// not say which (`RestoreText.entryResource`).
        let turnNumber: Int?
        let title: String
    }

    /// The restore the "Done" line offers "Undo Restore" for.
    var restoreDone: RestoreDone? {
        guard case let .done(.restored(done), _) = content.body else { return nil }
        return done
    }

    /// How much of the bar stands in its row, widest first. The row takes
    /// the first that fits: the buttons keep their words at any width, so a
    /// row with one layout asked a narrow pane for more than it had. Each
    /// fit asks for no more than the one before it. Unread turns on their
    /// own keep "Review Unviewed" in the row in a 1280×800 window's column;
    /// the buttons stay, in `minimal`, down to one of two panes side by
    /// side in the review's narrowest column (about 197pt); in a pane
    /// narrower still, as narrow as a split allows (60 to 80pt), the row
    /// keeps only its words, and the pane is answered from the terminal and
    /// with ⌘⏎ (`SupervisionFootBarTests`).
    enum Fit: CaseIterable {
        /// Everything: the tag, the count, every button in words, and
        /// "⌘⏎" beside the primary one until the key is learned.
        case full
        /// Without "⌘⏎", which the primary button's tooltip names, and with
        /// "Review Unviewed" at the head of the ⋯.
        case folded
        /// Also without the tag, whose meaning the bar's color, the primary
        /// button, and the sentence still carry, and which VoiceOver reads
        /// ahead of the sentence; the count moved into the ⋯ as "Show Next
        /// Item"; and the primary button and "Undo Restore" in their short
        /// forms, whole in their tooltips and VoiceOver labels. Chosen while
        /// its buttons fit at all, the sentence cut as short as it must be.
        case minimal
        /// The words alone, for a pane too narrow for any button: a button
        /// laid out past the pane's edge would be cut from sight but still
        /// take clicks there.
        case wordsOnly
    }

    /// How the row is drawn in one fit.
    struct Shape: Equatable {
        var showsTag: Bool
        /// Whether the count stands beside the tag, rather than in the ⋯.
        var showsCount: Bool
        /// Whether the row has its buttons and its ⋯.
        var showsButtons: Bool
        /// Whether "Review Unviewed" stands beside "Mark as Viewed".
        var showsReview: Bool
        /// Whether "⌘⏎" may stand beside the primary button.
        var showsKeyHint: Bool
        /// Whether the primary button and "Undo Restore" take their short
        /// forms ("Resume", "Undo").
        var usesShortLabels: Bool
        /// Whether the fit is chosen only with the words at their least
        /// (`decisionBarTextMinWidth`) beside the rest; otherwise, while
        /// the rest fits at all.
        var keepsWordsFloor: Bool
        /// What the ⋯ holds, in groups with a separator between each;
        /// empty where the row has no ⋯.
        var moreSections: [[MoreItem]]
    }

    /// A move the bar's ⋯ offers.
    enum MoreItem: Equatable {
        /// The count's press, moved out of the row: the pane's next item.
        case showNext
        /// "Review Unviewed", folded out of the row.
        case review
        case showPartialChanges(AttentionItemID)
        case startNewConversation(AttentionItemID)
        case restore(RestoreEntry)
    }

    /// The row in `fit`. The ⋯ holds what left the row's start first, then
    /// what shows or starts something, then the restore, which rewrites
    /// files and so stands apart, last.
    func shape(_ fit: Fit, locale: Locale) -> Shape {
        let showsButtons = fit != .wordsOnly
        let isLeast = fit == .minimal || fit == .wordsOnly
        let showsCount = countText != nil && !isLeast
        let showsReview = offersReview && fit == .full
        var shows: [MoreItem] = []
        if offersReview, !showsReview {
            shows.append(.review)
        }
        if let stopItem {
            shows += [.showPartialChanges(stopItem), .startNewConversation(stopItem)]
        }
        let sections: [[MoreItem]] = [
            countText != nil && !showsCount ? [.showNext] : [],
            shows,
            restoreEntry(locale: locale).map { [.restore($0)] } ?? []
        ]
        return Shape(
            showsTag: tag != nil && !isLeast,
            showsCount: showsCount,
            showsButtons: showsButtons,
            showsReview: showsReview,
            showsKeyHint: primaryAction != nil && fit == .full,
            usesShortLabels: hasShortLabels && fit == .minimal,
            keepsWordsFloor: !isLeast,
            moreSections: showsButtons ? sections.filter { !$0.isEmpty } : []
        )
    }

    /// Whether a button the row shows has a short form: resuming, asking
    /// to be notified, and "Undo Restore". "Mark as Viewed" is short as it
    /// is.
    private var hasShortLabels: Bool {
        switch primaryAction {
        case .resume, .notifyAtReset: true
        case .markReviewed, .closeAllTabs, nil: restoreDone != nil
        }
    }

    /// The fits the row chooses among: each that draws the row otherwise
    /// than the one before it, and the full one alone for a bar with no
    /// buttons, where only the sentence gives way.
    func fits(locale: Locale) -> [Fit] {
        let hasButtons = primaryAction != nil || offersReview || stopItem != nil || undo != nil || restoreDone != nil
            || restoreEntry(locale: locale) != nil
        guard hasButtons else { return [.full] }
        var fits: [Fit] = []
        var last: Shape?
        for fit in Fit.allCases {
            let shape = shape(fit, locale: locale)
            if shape != last {
                fits.append(fit)
                last = shape
            }
        }
        return fits
    }

    /// `nextName` names the item ⌘J goes to next, for the line after an
    /// item was handled. `now` is the time a usage limit's reset is worded
    /// against.
    init(
        content: DecisionBarContent,
        resetNotice: UsageLimitResetNotice? = nil,
        now: Date = Date(),
        locale: Locale,
        nextName: (AttentionItemID) -> String? = { _ in nil }
    ) {
        self.content = content
        self.resetNotice = resetNotice
        countText = content.position.map { Self.positionText($0, locale: locale) }
        countSpokenText = content.position.map { position in
            let count = LocalizedStringResource(
                "Needs Attention in this pane: \(position.index) of \(position.count)",
                comment: "Decision bar, VoiceOver: which of the pane's items the bar shows"
            ).resolved(in: locale)
            return AgentStatusText.spokenList([count, Self.alsoPendingText(position.higherKind, locale: locale) ?? ""], locale: locale)
        }
        heldUntil = switch content.body {
        case let .approval(_, _, .card(deadline)), let .question(_, .card(deadline)): deadline
        default: nil
        }
        let words = Self.adding(
            content.backgroundWork,
            to: Self.words(for: content.body, resetNotice: resetNotice, now: now, locale: locale, nextName: nextName),
            locale: locale
        )
        tag = words.tag
        spokenTag = words.spokenTag ?? words.tag
        tone = words.tone
        text = words.text
        spokenText = words.spokenText ?? AgentStatusText.spoken(words.text, locale: locale)
        runs = words.runs ?? [ReceiptRun(text: words.text, role: Self.wholeRole(words.tone))]
        instruction = words.instruction
        shortInstruction = Self.shortInstruction(words.instruction, for: content.body, locale: locale)
    }

    /// "8:42 left", rounded up as the approval card counts.
    static func timeLeft(_ deadline: ServiceDeadline, now: SuspendingClock.Instant, locale: Locale) -> String {
        ApprovalCardModel.timeLeftText(for: deadline.remaining(at: now), locale: locale)
    }

    private struct Words {
        var tag: String?
        var tone: Tone
        var text: String
        var instruction: String?
        /// `text` in runs, for a receipt; `nil` draws it whole.
        var runs: [ReceiptRun]?
        /// The tag and the text as VoiceOver reads them, where they name
        /// a turn; `nil` reads `tag`, and `text` as a list.
        var spokenTag: String?
        var spokenText: String?
    }

    /// The role of a sentence drawn whole. Waits and stops lead with what
    /// they are about; a line at rest, a resume under way, and a "Done"
    /// read evenly.
    private static func wholeRole(_ tone: Tone) -> ReceiptRun.Role {
        tone == .waiting || tone == .stopped ? .emphasized : .plain
    }

    /// `words` with the background work after them, set off as one more
    /// fact of the receipt. Last, so the row's cut at the sentence's end
    /// (`SupervisionTruncation.sentence`) takes it before any of the
    /// turn's own facts, which are what the bar is about: in a narrow
    /// pane it gives way first without a fit of its own. Plain rather
    /// than in a color of its own: the run is finished, and nothing here
    /// waits on the person.
    private static func adding(_ work: BackgroundWork?, to words: Words, locale: Locale) -> Words {
        guard let work, let sentence = BackgroundWorkText.sentence(work, locale: locale) else { return words }
        var result = words
        result.text = AgentStatusText.joined([words.text, sentence], locale: locale)
        result.runs = (words.runs ?? [ReceiptRun(text: words.text, role: wholeRole(words.tone))]) + [
            ReceiptRun(text: AgentStatusText.separator(locale: locale), role: .quiet),
            ReceiptRun(text: sentence, role: .plain)
        ]
        result.spokenText = AgentStatusText.spokenList(
            [words.spokenText ?? AgentStatusText.spoken(words.text, locale: locale), sentence],
            locale: locale
        )
        return result
    }

    private static func words(
        for body: DecisionBarContent.Body,
        resetNotice: UsageLimitResetNotice?,
        now: Date,
        locale: Locale,
        nextName: (AttentionItemID) -> String?
    ) -> Words {
        switch body {
        case let .summary(fact):
            return Words(tone: .muted, text: SessionRowFactText.make(fact, locale: locale))
        case let .lastTurn(turn):
            return Words(
                tone: .muted,
                text: ReceiptText.receipt(turn, locale: locale),
                runs: ReceiptText.runs(turn, includesTurnNumber: true, emphasizesChanges: false, locale: locale),
                spokenText: ReceiptText.spokenReceipt(turn, locale: locale)
            )
        case let .approval(provider, action, answer):
            let agent = SessionRowFactText.agentName(.agent(provider), locale: locale)
            return Words(
                tag: LocalizedStringResource("Approval", comment: "Decision bar tag: an approval request").resolved(in: locale),
                tone: .waiting,
                text: approvalSentence(action, agent: agent).resolved(in: locale),
                instruction: instruction(for: answer, locale: locale)
            )
        case let .question(provider, answer):
            let agent = SessionRowFactText.agentName(.agent(provider), locale: locale)
            return Words(
                tag: LocalizedStringResource("Question").resolved(in: locale),
                tone: .waiting,
                text: LocalizedStringResource("\(agent) is asking a question.", comment: "Decision bar: a question from the agent")
                    .resolved(in: locale),
                instruction: instruction(for: answer, locale: locale)
            )
        case let .prompt(provider, wait):
            return promptWords(wait, provider: provider, locale: locale)
        case let .stopped(reason, resume):
            return stoppedWords(reason, resume: resume, resetNotice: resetNotice, now: now, locale: locale)
        case .resuming:
            return Words(
                tag: LocalizedStringResource("Resuming", comment: "Decision bar tag: the stopped conversation is being resumed")
                    .resolved(in: locale),
                tone: .muted,
                text: LocalizedStringResource(
                    "Loading the same conversation…",
                    comment: "Decision bar while the stopped conversation is being resumed"
                ).resolved(in: locale)
            )
        case let .unread(turn):
            return unreadWords(turn, locale: locale)
        case let .done(result, next):
            let name = next.flatMap(nextName)
            return Words(
                tone: .done,
                text: doneText(result, next: name, isSpoken: false, locale: locale),
                spokenText: AgentStatusText.spoken(doneText(result, next: name, isSpoken: true, locale: locale), locale: locale)
            )
        }
    }

    /// What an approval asks for, by what its tool does: the same three
    /// sentences whether Limpid holds the request or the agent's own prompt
    /// does.
    private static func approvalSentence(_ action: PromptApproval.Action, agent: String) -> LocalizedStringResource {
        switch action {
        case .fileChange:
            LocalizedStringResource("\(agent) wants to change files.", comment: "Decision bar: an approval to edit files")
        case .command:
            LocalizedStringResource("\(agent) wants to run a command.", comment: "Decision bar: an approval to run a command")
        case .other:
            LocalizedStringResource(
                "\(agent) is asking for approval.",
                comment: "Decision bar: an approval of a tool that neither edits files nor runs a command"
            )
        }
    }

    /// A wait Limpid does not hold, answered at the agent's own prompt. An
    /// approval and a question read as held ones do, their words in
    /// the tooltip (`textHelp`); a wait we cannot name is the agent's own
    /// words, else that it waits for a response.
    private static func promptWords(_ wait: PromptWait, provider: AgentKind?, locale: Locale) -> Words {
        let agent = provider.map { SessionRowFactText.agentName(.agent($0), locale: locale) }
        let instruction = instruction(for: .terminal, locale: locale)
        switch wait {
        case let .approval(approval):
            let text = agent.map { approvalSentence(approval.action, agent: $0) } ?? LocalizedStringResource("Needs approval")
            return Words(
                tag: LocalizedStringResource("Approval", comment: "Decision bar tag: an approval request").resolved(in: locale),
                tone: .waiting,
                text: text.resolved(in: locale),
                instruction: instruction
            )
        case .question:
            let text = agent.map {
                LocalizedStringResource("\($0) is asking a question.", comment: "Decision bar: a question from the agent")
            } ?? LocalizedStringResource("Needs answer")
            return Words(
                tag: LocalizedStringResource("Question").resolved(in: locale),
                tone: .waiting,
                text: text.resolved(in: locale),
                instruction: Self.instruction(for: .terminal, locale: locale)
            )
        case let .unclassified(detail):
            let waiting = agent.map {
                LocalizedStringResource(
                    "\($0) is waiting for a response.",
                    comment: "Decision bar: the agent waits at its prompt, neither a known approval nor a known question"
                )
            } ?? LocalizedStringResource("Needs response")
            return Words(
                tag: LocalizedStringResource(
                    "decisionBar.tag.response",
                    defaultValue: "Response",
                    comment: "Decision bar tag: the agent waits at its prompt, and Limpid cannot tell an approval from a question"
                ).resolved(in: locale),
                tone: .waiting,
                text: detail ?? waiting.resolved(in: locale),
                instruction: instruction
            )
        }
    }

    private static func instruction(for answer: DecisionBarContent.AnswerPlace, locale: Locale) -> String {
        let resource = switch answer {
        case .card:
            LocalizedStringResource(
                "Answer on the approval card",
                comment: "Decision bar: Limpid still holds the request, so the card answers it"
            )
        // The agent's own prompt is right above the bar, in the same pane:
        // "the terminal" names it, and which screen it is adds nothing.
        case .terminal:
            LocalizedStringResource("Answer in the terminal", comment: "Decision bar: where an approval or a question is answered")
        case .terminalAfterTimeout:
            LocalizedStringResource("Timed out. Answer in the terminal.")
        case .sending:
            LocalizedStringResource("Sending…")
        }
        return resource.resolved(in: locale)
    }

    /// Recorded turns are tagged with their numbers ("T7", "T6–T7") and say
    /// what they changed and their last check. An episode no turn record
    /// stands for is tagged "Unread" and says only that it finished.
    private static func unreadWords(_ turn: UnreadTurn, locale: Locale) -> Words {
        guard let numbers = turn.numbers else {
            return Words(
                tag: LocalizedStringResource("Unread").resolved(in: locale),
                tone: .unread,
                text: LocalizedStringResource(
                    "The turn finished",
                    comment: "Decision bar: an unread turn whose changes are not known yet"
                ).resolved(in: locale)
            )
        }
        var facts = [ReceiptText.changes(turn.changes, locale: locale)]
        if let check = turn.check {
            facts.append(ReceiptText.check(check, locale: locale))
        }
        return Words(
            tag: ReceiptText.turns(numbers, locale: locale),
            tone: .unread,
            text: AgentStatusText.joined(facts, locale: locale),
            runs: ReceiptText.runs(turn, includesTurnNumber: false, emphasizesChanges: true, locale: locale),
            spokenTag: ReceiptText.spokenTurns(numbers, locale: locale)
        )
    }

    private static func positionText(_ position: DecisionBarContent.Position, locale: Locale) -> String {
        let count = LocalizedStringResource(
            "\(position.index) / \(position.count)",
            comment: "Decision bar: which of the pane's items it shows"
        ).resolved(in: locale)
        return AgentStatusText.joined([count, alsoPendingText(position.higherKind, locale: locale) ?? ""], locale: locale)
    }

    /// "Approval also pending", when a higher-ranked item waits.
    private static func alsoPendingText(_ kind: DecisionBarContent.AlsoPending?, locale: Locale) -> String? {
        let resource: LocalizedStringResource? = switch kind {
        case .approval: LocalizedStringResource(
                "Approval also pending",
                comment: "Decision bar: a higher-ranked approval waits in this pane"
            )
        case .question: LocalizedStringResource(
                "Question also pending",
                comment: "Decision bar: a higher-ranked question waits in this pane"
            )
        case .response: LocalizedStringResource(
                "Response also pending",
                comment: "Decision bar: a higher-ranked wait at the agent's prompt, as neither approval nor question, waits in this pane"
            )
        case .stop: LocalizedStringResource("Stop also pending", comment: "Decision bar: a higher-ranked stop waits in this pane")
        case nil: nil
        }
        return resource?.resolved(in: locale)
    }

    /// A stop's words: why it stopped, and whether and how its
    /// conversation can be resumed. The reason alone, as the tag
    /// beside it already says "Stopped"; a stop with no reason worded says
    /// that the agent stopped, so the line is never empty.
    private static func stoppedWords(
        _ reason: StopReason,
        resume: DecisionBarContent.StopResume,
        resetNotice: UsageLimitResetNotice?,
        now: Date,
        locale: Locale
    ) -> Words {
        // The resume Limpid typed at relaunch failing is the stop itself:
        // said once, as what failed and where to look, rather than as the
        // list's reason followed by the same failure in other words.
        let isFailedRelaunchResume = reason == .notResumedAtLaunch && resume == .failed
        let why = isFailedRelaunchResume
            ? LocalizedStringResource(
                "Couldn’t resume the same conversation after Limpid relaunched.",
                comment: "Decision bar on a stop whose resume typed at relaunch came back with no conversation"
            ).resolved(in: locale)
            : StopReasonText.message(reason, locale: locale, now: now)
            ?? LocalizedStringResource(
                "The agent stopped.",
                comment: "Decision bar on a stop whose reason is not known, beside its Stopped tag"
            ).resolved(in: locale)
        // While the limit holds, resuming is not what the bar offers: it
        // says the notice is on its way once asked, and nothing more.
        let more: String? = if isFailedRelaunchResume {
            LocalizedStringResource(
                "Its terminal shows why.",
                comment: "Decision bar after a failed relaunch resume: the pane's terminal shows the agent's own words"
            ).resolved(in: locale)
        } else if let resetNotice {
            resetNotice == .requested
                ? LocalizedStringResource(
                    "You’ll be notified when it resets.",
                    comment: "Decision bar and menu bar on a usage limit stop: a notification will arrive when the limit resets"
                ).resolved(in: locale)
                : nil
        } else {
            resumeWords(resume, locale: locale)
        }
        let text = more.map { joined(why, $0, after: reason, locale: locale) } ?? why
        // The reason is what the bar is about; what follows it (the
        // conversation is saved, how to resume) reads plain.
        let runs = text.hasPrefix(why) && text != why
            ? [ReceiptRun(text: why, role: .emphasized), ReceiptRun(text: String(text.dropFirst(why.count)), role: .plain)]
            : nil
        return Words(
            tag: LocalizedStringResource("Stopped").resolved(in: locale),
            tone: .stopped,
            text: text,
            runs: runs
        )
    }

    /// Why a stop happened, then what follows it. A usage limit's reason
    /// ends without a full stop ("… · resets 6:36 PM"), so its next sentence
    /// is set apart with one; every other reason ends with its own.
    private static func joined(_ why: String, _ more: String, after reason: StopReason, locale: Locale) -> String {
        if case .usageLimit = reason {
            return LocalizedStringResource(
                "decisionBar.usageLimitAndMore",
                defaultValue: "\(why). \(more)",
                comment: "Decision bar on a usage limit stop: the limit and its reset, then the next sentence"
            ).resolved(in: locale)
        }
        // Japanese runs its sentences on with no space, as the restore
        // strip does; an agent's own error keeps its words, most often
        // English, and keeps a space after them so the next sentence
        // does not touch them.
        if why.last?.isASCII == true {
            return "\(why) \(more)"
        }
        return LocalizedStringResource(
            "decisionBar.stopAndResume",
            defaultValue: "\(why) \(more)",
            comment: "Decision bar on a stop: why it stopped, then whether the conversation can be resumed"
        ).resolved(in: locale)
    }

    /// Whether and how a stop's conversation can be resumed, in words.
    private static func resumeWords(_ resume: DecisionBarContent.StopResume, locale: Locale) -> String? {
        switch resume {
        case .available:
            LocalizedStringResource(
                "The conversation is saved.",
                comment: "Decision bar on a stop that can be resumed: the conversation can be picked up again"
            ).resolved(in: locale)
        case .failed:
            LocalizedStringResource(
                "Couldn’t resume the same conversation. Its terminal shows why.",
                comment: "Decision bar on a stop whose resume returned to the shell, or ran out of time, with no conversation"
            ).resolved(in: locale)
        case .blocked(.notAtShell):
            LocalizedStringResource(
                "The conversation is saved. To resume it, return the pane to its shell prompt.",
                comment: "Decision bar on a stop whose pane runs another program in front"
            ).resolved(in: locale)
        case .blocked(.draft):
            LocalizedStringResource(
                "The conversation is saved. To resume it, clear the prompt with Control-C.",
                comment: "Decision bar on a stop whose shell prompt has text typed at it"
            ).resolved(in: locale)
        case .unavailable, .resuming:
            nil
        }
    }

    /// `isSpoken` leaves out the "(⌘J)" the line shows: in VoiceOver's
    /// reading the key's symbols would bury the name of what comes next.
    private static func doneText(
        _ result: DecisionBarContent.DoneResult,
        next: String?,
        isSpoken: Bool,
        locale: Locale
    ) -> String {
        // A sentence of its own: what comes next is Return in this pane.
        if case let .insertedReview(kind) = result {
            let agent = SessionRowFactText.agentName(.agent(kind), locale: locale)
            return LocalizedStringResource(
                "Inserted the comments into \(agent)’s input. Press Return to send.",
                comment: "Decision bar after the review's comments were inserted; argument: what runs in the pane"
            ).resolved(in: locale)
        }
        // The record's own words: what the working tree holds now and what
        // the conversation does not know matter more than what is next.
        if case let .restored(done) = result {
            let record = RestoreText.record(turnNumber: done.turnNumber, isPartial: false, locale: locale)
            return "\(record) · \(RestoreText.notInConversation(locale: locale))"
        }
        // What comes next is the person's next instruction, in this pane.
        if case .resumed = result {
            return LocalizedStringResource(
                "Resumed the same conversation. Type your next instruction in the terminal.",
                comment: "Decision bar after the stopped conversation was resumed"
            ).resolved(in: locale)
        }
        let outcome = switch result {
        case .answeredInTerminal:
            LocalizedStringResource(
                "Answered in the terminal",
                comment: "Decision bar: a request handed to the terminal was answered there"
            )
            .resolved(in: locale)
        case .declinedInTerminal:
            LocalizedStringResource(
                "Declined in the terminal",
                comment: "Decision bar: a question or permission prompt was declined at the terminal (Esc), stopping the turn"
            )
            .resolved(in: locale)
        case .markedViewed:
            LocalizedStringResource(
                "Marked as viewed",
                comment: "Decision bar: the person marked the pane's turns viewed; followed by what is next"
            )
            .resolved(in: locale)
        case .insertedReview, .resumed, .restored:
            ""
        }
        guard let next else {
            return LocalizedStringResource(
                "\(outcome). Nothing needs attention.",
                comment: "Decision bar after an item was handled; argument: what happened"
            ).resolved(in: locale)
        }
        if isSpoken {
            return LocalizedStringResource(
                "\(outcome). Next: “\(next)”.",
                comment: "Decision bar, VoiceOver: after an item was handled; arguments: what happened, the item Command-J goes to next"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "\(outcome). Next: “\(next)” (⌘J).",
            comment: "Decision bar after an item was handled; arguments: what happened, the item ⌘J goes to next"
        ).resolved(in: locale)
    }
}

extension DecisionBarModel {
    /// How a pane's "Done" line changes as its items change.
    enum DoneUpdate: Equatable {
        case keep
        case clear
        case set(DecisionBarContent.DoneResult)
    }

    /// The bar says "Done" once the item it showed leaves a pane that has
    /// nothing else waiting, and only for a request answered or declined at
    /// the terminal: one handed to the provider's prompt or left there when
    /// Limpid's time ran out, or a wait at that prompt. An item still
    /// waiting, or arriving, takes the bar back.
    ///
    /// `isDeclined`: the person declined the request at that prompt rather
    /// than answering it (`isDeclined(runtime:turn:)`), so the line says
    /// so: an answer goes on with the turn, and a decline stopped it.
    ///
    /// `hasMovedOnSinceShown`: a turn began in the pane, or its agent left,
    /// since the item was shown (`PaneRunLedger.epoch(inPane:)`). An item
    /// that left with them was not answered there, or its answer is past:
    /// the person quit the agent at its prompt, or sent the next prompt,
    /// and the line would stay under a shell or a turn it says nothing of.
    static func doneUpdate(
        lastShown: AttentionItem?,
        items: [AttentionItem],
        hasMovedOnSinceShown: Bool,
        isDeclined: Bool = false
    ) -> DoneUpdate {
        guard items.isEmpty else { return .clear }
        guard let lastShown, !hasMovedOnSinceShown else { return .keep }
        let done: DecisionBarContent.DoneResult = isDeclined ? .declinedInTerminal : .answeredInTerminal
        switch lastShown.kind {
        case let .approval(fact), let .question(fact):
            return fact.state.isLeftToTerminal ? .set(done) : .keep
        case .prompt:
            return .set(done)
        case .stop, .unread:
            return .keep
        }
    }

    /// Whether the run an item left was declined at its prompt rather than
    /// answered there: Claude sends no hook for an Esc at its question or
    /// permission prompt. The projection reads the decline from the
    /// transcript and says so on the badge until the record is written
    /// (`AgentBadge.isWaitDeclined`); once it is, or when the agent's idle
    /// prompt ended the wait, the run rests finished with its turn ended
    /// `interrupted`. An answer moves the run on to work instead, and a turn
    /// that went on to finish ends `finished`.
    static func isDeclined(runtime: AgentRuntimePresentation?, turn: TurnSummary?) -> Bool {
        guard let runtime else { return false }
        if runtime.badge.isWaitDeclined {
            return true
        }
        return runtime.badge.state == .finished && turn?.phase == .interrupted
    }
}
