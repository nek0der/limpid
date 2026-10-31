// NotificationHistoryRowText.swift
// Weir — a notification history row's two lines: what it is about, then what came of it; and where it came from.

import Foundation
import WeirDomain

/// A history row in two lines: what it is about first (the instruction a
/// turn answered, the command an approval asks about), then what came of
/// it (the reply, "Needs approval") with the facts at its end ("T4 +94 −0",
/// "exit 1"). What happened is said in words only where the row has nothing
/// more particular; the glyph says it on every row. Where the row came from
/// is its source's heading (`NotificationHistoryList`), said once over its
/// rows.
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
        case signIn
        case stopped
        case idle
    }

    /// What happened, as an entry tells it.
    enum Happening: Equatable {
        case wait(NotificationEvent.Wait, fact: String?)
        /// `receipt` is the turn's facts, empty when none were kept;
        /// `reply` is what the agent said as it ended.
        case turn(receipt: [ReceiptRun], instruction: String?, reply: String?)
        case stopped(reason: String?)
        case command(exitCode: Int?, durationSeconds: Double?, tabTitle: String?)
        /// An OSC 9/777 alert or a bell, in its own words.
        case alert(title: String, body: String)
    }

    struct Lines: Equatable {
        /// What happened: "Needs approval", "Turn finished". Drawn only
        /// where the row has nothing more particular to say, and always
        /// read by VoiceOver.
        let headline: String
        /// The first line: what the row is about. The instruction a turn
        /// answered, what a wait names, why the agent stopped; else the
        /// headline.
        let subject: String
        /// Whether the subject is a file's name or a command, which the
        /// line cuts in the middle so both ends stay; prose is cut at its end.
        let isSubjectAName: Bool
        /// The second line: what came of it. `nil` when the subject said
        /// all there is.
        let outcome: Outcome?
        /// At the second line's end: the turn's number and counts, a
        /// command's exit and time. Empty when there are none.
        let facts: [ReceiptRun]

        /// The facts on one run, as the row draws them.
        var factsText: String {
            facts.map(\.text).joined()
        }

        /// Every line whole, for the tooltip, which the row may cut; the
        /// reply said as one, as VoiceOver says it.
        func help(locale: Locale) -> String {
            let second = outcome.map { $0.text(headline: headline, locale: locale) }
            return [subject, second, facts.isEmpty ? nil : factsText].compactMap(\.self).joined(separator: "\n")
        }
    }

    /// A row's second line.
    enum Outcome: Equatable {
        /// The headline, in the tone the glyph is in: "Needs approval"
        /// under the command it asks about.
        case headline
        /// What the agent said as its turn ended.
        case reply(String)
        /// An alert's body.
        case detail(String)

        func text(headline: String, locale: Locale) -> String {
            switch self {
            case .headline: headline
            case let .reply(reply): TurnReplyText.labeled(reply, locale: locale)
            case let .detail(detail): detail
            }
        }
    }

    // MARK: - Lines

    /// `sourceTabTitle` is the tab its heading names, so a command's row
    /// names its own tab only when it was another.
    static func lines(of entry: NotificationEntry, sourceTabTitle: String?, locale: Locale) -> Lines {
        lines(of: happening(of: entry, locale: locale), sourceTabTitle: sourceTabTitle, locale: locale)
    }

    static func lines(of happening: Happening, sourceTabTitle: String?, locale: Locale) -> Lines {
        switch happening {
        case let .wait(wait, fact):
            return named(fact, headline: waitName(wait, locale: locale), isAName: wait == .approval)
        case let .turn(receipt, instruction, reply):
            let headline = LocalizedStringResource(
                "Turn finished",
                comment: "Notification history: the headline of a finished turn"
            ).resolved(in: locale)
            // The instruction tells one turn from the next; the reply is
            // what came of it, else the headline says the turn ended.
            let outcome: Outcome? = reply.map(Outcome.reply) ?? (instruction == nil ? nil : .headline)
            return Lines(headline: headline, subject: instruction ?? headline, isSubjectAName: false, outcome: outcome, facts: receipt)
        case let .stopped(reason):
            return named(reason, headline: LocalizedStringResource("Stopped").resolved(in: locale), isAName: false)
        case let .command(exitCode, durationSeconds, tabTitle):
            let hasFailed = (exitCode ?? 0) != 0
            let headline = hasFailed
                ? LocalizedStringResource("Command failed", comment: "Notification history: a command that exited with a nonzero status")
                : LocalizedStringResource("Command finished", comment: "Notification history: a command that exited with status 0")
            let exit = exitCode.flatMap { code in
                code == 0 ? nil : ReceiptRun(text: exitCodeText(code, locale: locale), role: .failed)
            }
            let duration = durationSeconds.map { ReceiptRun(text: DurationText.command($0, locale: locale), role: .plain) }
            // The tab only when the heading names another: a shell's heading
            // names the tab of its newest row.
            let tab = tabTitle.flatMap { $0.isEmpty || $0 == sourceTabTitle ? nil : $0 }
            let lines = named(tab, headline: headline.resolved(in: locale), isAName: false)
            return Lines(
                headline: lines.headline,
                subject: lines.subject,
                isSubjectAName: false,
                outcome: lines.outcome,
                facts: spaced([exit, duration].compactMap(\.self).map { [$0] })
            )
        case let .alert(title, body):
            let message = message(body, locale: locale)
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return Lines(headline: message, subject: message, isSubjectAName: false, outcome: nil, facts: [])
            }
            return Lines(
                headline: title,
                subject: title,
                isSubjectAName: false,
                outcome: message.isEmpty ? nil : .detail(message),
                facts: []
            )
        }
    }

    /// `name` on the first line and the headline under it, in the glyph's
    /// tone; the headline alone when nothing was named.
    private static func named(_ name: String?, headline: String, isAName: Bool) -> Lines {
        guard let name else {
            return Lines(headline: headline, subject: headline, isSubjectAName: false, outcome: nil, facts: [])
        }
        return Lines(headline: headline, subject: name, isSubjectAName: isAName, outcome: .headline, facts: [])
    }

    /// Groups of runs a space apart, as the second line's end sets its facts.
    private static func spaced(_ groups: [[ReceiptRun]]) -> [ReceiptRun] {
        groups.enumerated().flatMap { index, group in
            index == 0 ? group : [ReceiptRun(text: " ", role: .quiet)] + group
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

    /// "exit 1": a failed command's status, among its row's facts.
    static func exitCodeText(_ code: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "exit \(code)",
            comment: "A failed command's exit status: after Command failed in the notification history, and as a pane strip tab's mark"
        ).resolved(in: locale)
    }

    /// The wait's name, as the glyph's own label and the decision bar name
    /// it: "Needs approval", "Needs answer", "Needs response", "Needs
    /// sign-in".
    static func waitName(_ wait: NotificationEvent.Wait, locale: Locale) -> String {
        let glyph: SessionRowFact.Glyph = switch wait {
        case .approval: .needsApproval
        case .question: .needsAnswer
        case .response: .needsResponse
        case .signIn: .needsSignIn
        }
        return SessionRowFactText.stateName(glyph, locale: locale)
    }

    /// What VoiceOver reads for a row: what it is about, what came of it,
    /// what happened when the row does not draw it, its facts, when, and
    /// whether it is unread. The source is its heading's, read before it.
    static func spokenLabel(_ lines: Lines, timeLabel: String, isUnread: Bool, locale: Locale) -> String {
        // The facts as a list and a turn in words: a receipt kept as text
        // still holds " · ", and "T7" would be read letter by letter.
        let facts = lines.factsText
            .components(separatedBy: AgentStatusText.separator(locale: locale))
            .map { fact in
                fact.split(separator: " ").map { ReceiptText.spokenFact(String($0), locale: locale) }.joined(separator: " ")
            }
        let isHeadlineDrawn = lines.subject == lines.headline || lines.outcome == .headline
        return AgentStatusText.spokenList(
            [
                AgentStatusText.spoken(lines.subject, locale: locale),
                lines.outcome.map { $0.text(headline: lines.headline, locale: locale) } ?? "",
                isHeadlineDrawn ? "" : lines.headline,
                AgentStatusText.spokenList(facts, locale: locale),
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
            case .signIn: .signIn
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
            return .turn(receipt: receipt.map { receiptRuns(recorded: $0, locale: locale) } ?? [], instruction: instruction, reply: nil)
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
        case let .turnFinished(_, turn, prompt, promptKind, reply):
            let instruction = TurnPromptText.instruction(TurnPrompt(kind: promptKind, head: prompt), locale: locale)
            return .turn(receipt: turn.map { receiptRuns($0, locale: locale) } ?? [], instruction: instruction, reply: reply)
        case let .stopped(_, reason):
            return .stopped(reason: words(reason))
        }
    }

    /// "T4 +94 −0 ✓ Tests": the turn, its counts in the diff colors with
    /// a count of zero quiet, since it is not a change, and its check. The
    /// files counted and "No file changes" are left to the Changes panel:
    /// at a row's end the counts say how much changed, and nothing at all
    /// says nothing did.
    static func receiptRuns(_ turn: NotificationEvent.Turn, locale: Locale) -> [ReceiptRun] {
        var groups: [[ReceiptRun]] = [[ReceiptRun(text: ReceiptText.turns(turn.number...turn.number, locale: locale), role: .plain)]]
        if case let .changed(_, added, removed) = turn.changes {
            groups.append(countRuns(added: added, removed: removed, locale: locale))
        }
        if let check = turn.check {
            groups.append([ReceiptRun(text: ReceiptText.check(check, locale: locale), role: check.hasFailed ? .failed : .plain)])
        }
        return spaced(groups)
    }

    /// "+94 −0" in the diff colors, a count of zero quiet.
    private static func countRuns(added: Int, removed: Int, locale: Locale) -> [ReceiptRun] {
        [
            ReceiptRun(text: ReceiptText.signed(added, sign: "+", locale: locale), role: added == 0 ? .quiet : .added(isEmphasized: false)),
            ReceiptRun(text: " ", role: .quiet),
            ReceiptRun(
                text: ReceiptText.signed(removed, sign: "−", locale: locale),
                role: removed == 0 ? .quiet : .removed(isEmphasized: false)
            )
        ]
    }

    /// A receipt recorded as text, as `receiptRuns` sets one from an event:
    /// "T7 · 2 files +3 −1 · ✗ Tests" is "T7 +3 −1 ✗ Tests", so a row from
    /// before events ends as a newer one does. What says only that nothing
    /// changed ("Answer only") goes, in whichever language it was recorded.
    /// A line that does not begin as a receipt is kept whole.
    private static func receiptRuns(recorded text: String, locale: Locale) -> [ReceiptRun] {
        guard LegacyText.isReceipt(text) else { return [ReceiptRun(text: text, role: .plain)] }
        let parts = text.components(separatedBy: " · ")
        var groups: [[ReceiptRun]] = [[ReceiptRun(text: parts[0], role: .plain)]]
        for part in parts.dropFirst() {
            if let match = part.firstMatch(of: /\+([\d,]+) −([\d,]+)/),
               let added = Int(match.1.filter(\.isNumber)),
               let removed = Int(match.2.filter(\.isNumber))
            {
                groups.append(countRuns(added: added, removed: removed, locale: locale))
            } else if part.hasPrefix("✗") {
                groups.append([ReceiptRun(text: part, role: .failed)])
            } else if part.hasPrefix("✓") {
                groups.append([ReceiptRun(text: part, role: .plain)])
            }
        }
        return spaced(groups)
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
            for wait in [NotificationEvent.Wait.approval, .question, .response, .signIn] {
                bare[NotificationHistoryRowText.waitName(wait, locale: locale)] = wait
            }
            for agent in AgentKind.allCases {
                bare[agent.waitTitle(for: .approval(PromptApproval(tool: nil, action: .other, subject: nil, detail: nil)))
                    .resolved(in: locale)] = .approval
                bare[agent.waitTitle(for: .question(detail: nil)).resolved(in: locale)] = .question
                bare[agent.waitTitle(for: .signIn).resolved(in: locale)] = .signIn
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
        case .signIn: (.signIn, nil)
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
    static func isReceipt(_ line: String) -> Bool {
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
