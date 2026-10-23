// NotificationHistoryRowText.swift
// Limpid — a notification history row's two lines: what happened, then its detail; and where it came from.

import Foundation

/// A history row in two lines: what happened first ("Needs approval",
/// "Turn finished · T4 · 2 files +94 −0", "Command failed · exit 1"), then
/// the instruction or detail, quiet, on one line. Where the row came from is
/// its source's heading (`NotificationHistoryList`), said once over its rows.
///
/// An agent's entry is worded from its event, in the window's language. An
/// entry from before events, or with one this build cannot read, is read
/// from the title and body it recorded, in either of the languages it may
/// have been recorded in.
enum NotificationHistoryRowText {
    /// One per locale: every row of the history asks once a minute, and a
    /// formatter costs more to make than to use.
    private static let relativeFormatters = RelativeFormatterCache()
    /// Where an entry came from.
    struct Place: Equatable {
        let name: String
        /// The project, when the entry's pane still says which; `nil` for
        /// scratch and for a pane that is gone, which says nothing of the
        /// window.
        let projectID: UUID?
    }

    /// The row's state glyph. Amber and red only while the agent is still
    /// in the state the row reported, so a row answered long ago does not
    /// look as if it still waits.
    enum Mark: Equatable {
        case approval
        case question
        case response
        case stopped
        case idle
    }

    /// What happened, as an entry tells it.
    enum Happening: Equatable {
        case wait(NotificationEvent.Wait, fact: String?)
        /// `receipt` is the turn's facts, empty when none were kept.
        case turn(receipt: [ReceiptRun], instruction: String?)
        case stopped(reason: String?)
        case command(exitCode: Int?, durationSeconds: Double?, tabTitle: String?)
        /// An OSC 9/777 alert or a bell, in its own words.
        case alert(title: String, body: String)
    }

    struct Lines: Equatable {
        /// What happened: "Needs approval", "Turn finished".
        let headline: String
        /// The facts after it, set off by the separator: the receipt, the
        /// exit code. Empty when there are none.
        let facts: [ReceiptRun]
        /// The second line; `nil` when there is nothing to add.
        let detail: String?
        /// Whether the detail is a file's name or a command, which the line
        /// cuts in the middle so both ends stay; prose is cut at its end.
        let isDetailASubject: Bool

        /// The first line whole, for the tooltip and VoiceOver.
        var firstLine: String {
            facts.reduce(headline) { $0 + $1.text }
        }
    }

    // MARK: - Lines

    /// `sourceTabTitle` is the tab its heading names, so a command's row
    /// names its own tab only when it was another.
    static func lines(of entry: NotificationEntry, sourceTabTitle: String?, locale: Locale) -> Lines {
        lines(of: happening(of: entry, locale: locale), sourceTabTitle: sourceTabTitle, locale: locale)
    }

    static func lines(of happening: Happening, sourceTabTitle: String?, locale: Locale) -> Lines {
        let separator = ReceiptRun(text: AgentStatusText.separator(locale: locale), role: .quiet)
        switch happening {
        case let .wait(wait, fact):
            return Lines(headline: waitName(wait, locale: locale), facts: [], detail: fact, isDetailASubject: wait == .approval)
        case let .turn(receipt, instruction):
            return Lines(
                headline: LocalizedStringResource(
                    "Turn finished",
                    comment: "Notification history: the headline of a finished turn"
                ).resolved(in: locale),
                facts: receipt.isEmpty ? [] : [separator] + receipt,
                detail: instruction,
                isDetailASubject: false
            )
        case let .stopped(reason):
            return Lines(
                headline: LocalizedStringResource("Stopped").resolved(in: locale),
                facts: [],
                detail: reason,
                isDetailASubject: false
            )
        case let .command(exitCode, durationSeconds, tabTitle):
            let hasFailed = (exitCode ?? 0) != 0
            let headline = hasFailed
                ? LocalizedStringResource("Command failed", comment: "Notification history: a command that exited with a nonzero status")
                : LocalizedStringResource("Command finished", comment: "Notification history: a command that exited with status 0")
            let facts = exitCode.flatMap { code in
                code == 0 ? nil : [separator, ReceiptRun(text: exitCodeText(code, locale: locale), role: .plain)]
            } ?? []
            // The tab only when the heading names another: a shell's heading
            // names the tab of its newest row.
            let tab = tabTitle.flatMap { $0.isEmpty || $0 == sourceTabTitle ? nil : $0 }
            let duration = durationSeconds.map { DurationText.command($0, locale: locale) }
            let detail = AgentStatusText.joined([tab ?? "", duration ?? ""], locale: locale)
            return Lines(
                headline: headline.resolved(in: locale),
                facts: facts,
                detail: detail.isEmpty ? nil : detail,
                isDetailASubject: false
            )
        case let .alert(title, body):
            let message = message(body, locale: locale)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return Lines(headline: message, facts: [], detail: nil, isDetailASubject: false)
            }
            return Lines(headline: title, facts: [], detail: message.isEmpty ? nil : message, isDetailASubject: false)
        }
    }

    /// When a row came: "now", then relative within a day, then the date.
    /// Counted from `now`, which the history's timeline moves on every
    /// minute while it is open, as the sidebar's and Needs Attention's do:
    /// read from the clock instead, the times stood still until something
    /// else redrew the list.
    static func timeLabel(for entry: NotificationEntry, now: Date, locale: Locale) -> String {
        let delta = now.timeIntervalSince(entry.timestamp)
        if delta < 60 {
            return LocalizedStringResource("now").resolved(in: locale)
        }
        if delta < 86400 {
            // Recent entries get a locale-aware abbreviated relative
            // form ("5 min. ago" / "5 分前"), in the window's locale rather
            // than `Locale.current`, whose language is the launch one.
            // The formatter rather than `.relative`, which counts from the
            // clock and takes no `now`; its `.short` is that style's `.abbreviated`.
            return relativeFormatters.formatter(for: locale)
                .localizedString(for: entry.timestamp, relativeTo: now)
        }
        // Older entries take the locale's own abbreviated date rather than a
        // hand-pinned "MM/dd", so each locale sees its own shape ("Jun 4, 2026"
        // in English).
        return entry.timestamp.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// "exit 1": a failed command's status, after its headline.
    static func exitCodeText(_ code: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "exit \(code)",
            comment: "A failed command's exit status: after Command failed in the notification history, and as a pane strip tab's mark"
        ).resolved(in: locale)
    }

    /// The wait's name, as the glyph's own label and the decision bar name
    /// it: "Needs approval", "Needs answer", "Needs response".
    static func waitName(_ wait: NotificationEvent.Wait, locale: Locale) -> String {
        let glyph: SessionRowFact.Glyph = switch wait {
        case .approval: .needsApproval
        case .question: .needsAnswer
        case .response: .needsResponse
        }
        return SessionRowFactText.stateName(glyph, locale: locale)
    }

    /// What VoiceOver reads for a row: what happened, its detail, when, and
    /// whether it is unread. The source is its heading's, read before it.
    static func spokenLabel(_ lines: Lines, timeLabel: String, isUnread: Bool, locale: Locale) -> String {
        // The facts as a list and a turn in words: the line's " · " and
        // "T7" would be read as a symbol and letter by letter.
        let first = lines.firstLine
            .components(separatedBy: AgentStatusText.separator(locale: locale))
            .map { ReceiptText.spokenFact($0, locale: locale) }
        return AgentStatusText.spokenList(
            [
                AgentStatusText.spokenList(first, locale: locale),
                AgentStatusText.spoken(lines.detail ?? "", locale: locale),
                timeLabel,
                isUnread ? LocalizedStringResource("Unread").resolved(in: locale) : ""
            ],
            locale: locale
        )
    }

    /// The body's paragraphs on one run: as sentences where one ends, else
    /// with the separator the row's facts use.
    static func message(_ body: String, locale: Locale) -> String {
        let paragraphs = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = paragraphs.first else { return "" }
        return paragraphs.dropFirst().reduce(first) { text, next in
            endsASentence(text)
                ? RestoreText.joined([text, next], locale: locale)
                : AgentStatusText.joined([text, next], locale: locale)
        }
    }

    private static func endsASentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?:。！？：".contains(last)
    }

    // MARK: - Mark

    /// The row's glyph. A closed source's rows rest; a wait or a stop the
    /// agent is still in is amber or red, and one it has left rests; a row
    /// with nothing live to ask (a command, a row from before event tokens)
    /// is colored only while unread. A finished turn, a command that
    /// succeeded, and an alert always rest.
    static func mark(
        of entry: NotificationEntry,
        happening: Happening,
        liveStatus: NotificationLiveStatus?,
        isSourceClosed: Bool
    ) -> Mark {
        guard !isSourceClosed else { return .idle }
        let alarm: Mark? = switch happening {
        case let .wait(wait, _):
            switch wait {
            case .approval: .approval
            case .question: .question
            case .response: .response
            }
        case .stopped: .stopped
        case let .command(exitCode, _, _): (exitCode ?? 0) != 0 ? .stopped : nil
        case .turn, .alert: nil
        }
        guard let alarm else { return .idle }
        switch liveStatus {
        case .stillWaiting?: return alarm
        case .resolved?: return .idle
        case nil: return entry.isRead ? .idle : alarm
        }
    }

    // MARK: - Reading an entry

    /// What happened, from the entry's event, else from what it recorded.
    static func happening(of entry: NotificationEntry, locale: Locale) -> Happening {
        if let event = entry.event {
            return happening(of: event, locale: locale)
        }
        switch entry.kind {
        case .agentNeedsInput:
            let (wait, fact) = LegacyText.wait(entry.body, hasRequest: entry.requestKey != nil)
            return .wait(wait, fact: fact)
        case .agentFinished:
            let (receipt, instruction) = LegacyText.turn(entry.body)
            return .turn(receipt: receipt.map { [ReceiptRun(text: $0, role: .plain)] } ?? [], instruction: instruction)
        case .agentError:
            return .stopped(reason: LegacyText.stopReason(entry.body))
        case .commandFinished:
            return .command(exitCode: entry.exitCode, durationSeconds: entry.durationSeconds, tabTitle: entry.tabTitleSnapshot)
        case .desktop, .bell:
            return .alert(title: entry.title, body: entry.body)
        }
    }

    static func happening(of event: NotificationEvent, locale: Locale) -> Happening {
        switch event {
        case let .wait(_, wait, fact):
            return .wait(wait, fact: words(fact))
        case let .turnFinished(_, turn, prompt, promptKind):
            let instruction = TurnPromptText.instruction(TurnPrompt(kind: promptKind, head: prompt), locale: locale)
            return .turn(receipt: turn.map { receiptRuns($0, locale: locale) } ?? [], instruction: instruction)
        case let .stopped(_, reason):
            return .stopped(reason: words(reason))
        }
    }

    /// "T4 · 2 files +94 −0 · ✓ Tests", its counts in the diff colors and a
    /// count of zero quiet, since it is not a change.
    static func receiptRuns(_ turn: NotificationEvent.Turn, locale: Locale) -> [ReceiptRun] {
        var parts: [[ReceiptRun]] = [[ReceiptRun(text: ReceiptText.turns(turn.number...turn.number, locale: locale), role: .plain)]]
        var changes = ReceiptText.changeRuns(turn.changes, isEmphasized: false, locale: locale)
        if case let .changed(_, added, removed) = turn.changes {
            changes = changes.map { run in
                switch run.role {
                case .added where added == 0, .removed where removed == 0: ReceiptRun(text: run.text, role: .quiet)
                default: run
                }
            }
        }
        parts.append(changes)
        if let check = turn.check {
            parts.append([ReceiptRun(text: ReceiptText.check(check, locale: locale), role: check.hasFailed ? .failed : .plain)])
        }
        let separator = ReceiptRun(text: AgentStatusText.separator(locale: locale), role: .quiet)
        return parts.enumerated().flatMap { index, part in index == 0 ? part : [separator] + part }
    }

    private static func words(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Place

    /// Whether `place` is another window's: a project one of the windows
    /// other than the history's shows, hidden ones included, as the Needs
    /// Attention list says it (`NeedsAttentionListModel.isInAnotherWindow`).
    /// Scratch, a place no pane names, and a project no window shows are
    /// not: opening the row switches this window there.
    static func isInAnotherWindow(_ place: Place, projectsInOtherWindows: Set<UUID>) -> Bool {
        place.projectID.map(projectsInOtherWindows.contains) ?? false
    }

    /// Where `entry` came from: its pane's project, and worktree when it
    /// is in one, while the pane is open; "Scratch" for a pane outside any
    /// project; once the pane is gone, the container it fired in, else the
    /// label the entry recorded as it arrived.
    @MainActor
    static func place(of entry: NotificationEntry, in session: WorkspaceSession, locale: Locale) -> Place? {
        if let paneID = entry.paneID, let tab = session.tab(containing: paneID) {
            guard let projectID = tab.container.projectID, session.project(projectID) != nil else {
                return Place(name: LocalizedStringResource("Scratch").resolved(in: locale), projectID: nil)
            }
            return Place(name: session.containerLabel(for: tab.container, locale: locale), projectID: projectID)
        }
        // The pane is gone: the container it fired in, named as the window
        // names it while it still exists, else as it was recorded.
        if let container = entry.containerID {
            if container == .loose {
                return Place(name: LocalizedStringResource("Scratch").resolved(in: locale), projectID: nil)
            }
            if let projectID = container.projectID, session.project(projectID) != nil {
                return Place(name: session.containerLabel(for: container, locale: locale), projectID: projectID)
            }
        }
        guard let label = entry.containerLabel, !label.isEmpty else { return nil }
        return Place(name: label, projectID: nil)
    }
}

/// An entry recorded before events, read from its words. The body was
/// written in the language the app showed then, so both the languages it
/// ships in are tried, through the same functions that wrote it: the
/// session row's wait ("Waiting for approval: notes.txt"), the agents'
/// titles, which stand in for a body with nothing to name.
private enum LegacyText {
    static let locales = [Locale(identifier: "en"), Locale(identifier: "ja")]

    /// Splits off the argument of a worded wait: what comes before it, and
    /// the wait it is.
    private static let marker = "\u{1}"

    private struct Phrase {
        let wait: NotificationEvent.Wait
        /// The words before the wait's fact ("Waiting for approval: ").
        let prefix: String
    }

    private static let prefixes: [Phrase] = locales.flatMap { locale in
        [
            (NotificationEvent.Wait.approval, PromptWait.approval(PromptApproval(tool: nil, action: .other, subject: marker, detail: nil))),
            (.question, PromptWait.question(detail: marker)),
            (.response, PromptWait.unclassified(detail: marker))
        ].compactMap { wait, worded in
            let text = PromptWaitText.line(worded).resolved(in: locale)
            return text.range(of: marker).map { Phrase(wait: wait, prefix: String(text[..<$0.lowerBound])) }
        }
    }

    /// The body of a wait with nothing to name: the state's name, or an
    /// agent's "is waiting" title.
    private static let bareWaits: [String: NotificationEvent.Wait] = {
        var bare: [String: NotificationEvent.Wait] = [:]
        for locale in locales {
            for wait in [NotificationEvent.Wait.approval, .question, .response] {
                bare[NotificationHistoryRowText.waitName(wait, locale: locale)] = wait
            }
            for agent in AgentKind.allCases {
                bare[agent.waitTitle(for: .approval(PromptApproval(tool: nil, action: .other, subject: nil, detail: nil)))
                    .resolved(in: locale)] = .approval
                bare[agent.waitTitle(for: .question(detail: nil)).resolved(in: locale)] = .question
                bare[agent.waitTitle(for: nil).resolved(in: locale)] = .response
            }
        }
        return bare
    }()

    /// The agents' titles that stood in for a finished turn's or a stop's
    /// body with nothing to say.
    private static let bareFinished = Set(locales.flatMap { locale in
        AgentKind.allCases.map { $0.finishedTitle.resolved(in: locale) }
    })

    private static let bareStops = Set(locales.flatMap { locale in
        AgentKind.allCases.map { $0.stoppedTitle.resolved(in: locale) }
    })

    /// Which wait the body was and what it named. A held request's body is
    /// an approval worded as a wait, or a question's own words. Anything
    /// else is read as a record's words are, which counts a tool's
    /// "Bash: swift test" as an approval and the rest as a wait for a
    /// response.
    static func wait(_ body: String, hasRequest: Bool) -> (NotificationEvent.Wait, String?) {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        for phrase in prefixes where text.hasPrefix(phrase.prefix) {
            let fact = text.dropFirst(phrase.prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return (phrase.wait, fact.isEmpty ? nil : fact)
        }
        if let wait = bareWaits[text] {
            return (wait, nil)
        }
        if hasRequest {
            return (.question, text.isEmpty ? nil : text)
        }
        return switch PromptWait(detail: text) {
        case let .approval(approval): (.approval, approval.fact)
        case let .question(detail): (.question, detail)
        case let .unclassified(detail): (.response, detail)
        }
    }

    /// The receipt on the body's first line, the instruction under it. A
    /// body of one line is the receipt when it begins as one ("T7"), else
    /// the instruction. An instruction a harness wrote is left out: before
    /// events it was quoted with its tags, and telling one apart is the
    /// projection's rule, not this one's.
    static func turn(_ body: String) -> (receipt: String?, instruction: String?) {
        let lines = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, !bareFinished.contains(first) || lines.count > 1 else { return (nil, nil) }
        let receipt: String?
        let rest: [String]
        if lines.count > 1 || isReceipt(first) {
            receipt = first
            rest = Array(lines.dropFirst())
        } else {
            receipt = nil
            rest = lines
        }
        let instruction = rest.joined(separator: " ")
        guard !instruction.isEmpty, !instruction.hasPrefix("<") else { return (receipt, nil) }
        return (receipt, instruction)
    }

    /// The stop's reason, unless the body only named the agent.
    static func stopReason(_ body: String) -> String? {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || bareStops.contains(text) ? nil : text
    }

    /// "T7 · …": the turn's number leads every receipt, in both languages.
    private static func isReceipt(_ line: String) -> Bool {
        line.first == "T" && line.dropFirst().first?.isNumber == true
    }
}

/// The history's relative-time formatters, one per locale, made on first
/// use. `@unchecked Sendable`: the dictionary is read and written only under
/// the lock, and a formatter, once made, is only used to format, which
/// Foundation's formatters allow from any thread.
private final class RelativeFormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [Locale: RelativeDateTimeFormatter] = [:]

    func formatter(for locale: Locale) -> RelativeDateTimeFormatter {
        lock.withLock {
            if let formatter = formatters[locale] {
                return formatter
            }
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .numeric
            formatter.unitsStyle = .short
            formatters[locale] = formatter
            return formatter
        }
    }
}
