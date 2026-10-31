// SessionRowFactText.swift
// Weir — a session row's second line and agent badge, in words.

import Foundation
import WeirDomain

enum SessionRowFactText {
    /// Returns the row's fact at `now`, its second line after the checkout a
    /// labeled row starts it with (`lineLead`). It is worded when the model was built,
    /// except a usage limit stop's, which names its reset only while it is
    /// ahead and so is worded again against the row's clock.
    static func current(_ row: SessionSidebarModel.Row, now: Date, locale: Locale) -> String {
        guard case let .stopped(.usageLimit(limit)) = row.fact.fact else { return row.factText }
        return StopReasonText.make(.usageLimit(limit), locale: locale, now: now)
    }

    static func make(_ fact: SessionRowFact.Fact, locale: Locale) -> String {
        switch fact {
        case let .question(text):
            text.map {
                LocalizedStringResource("Question: \($0)", comment: "Needs Attention row; the start of the agent's question")
                    .resolved(in: locale)
            } ?? LocalizedStringResource("Needs answer").resolved(in: locale)
        case let .approval(command):
            command.map {
                LocalizedStringResource(
                    "Waiting for approval: \($0)",
                    comment: "Needs Attention row; the command an approval request waits on"
                ).resolved(in: locale)
            } ?? LocalizedStringResource("Needs approval").resolved(in: locale)
        case let .prompt(wait):
            PromptWaitText.line(wait).resolved(in: locale)
        case let .stopped(reason):
            StopReasonText.make(reason, locale: locale)
        case let .unread(changes):
            unread(changes, locale: locale)
        case let .running(action):
            action ?? LocalizedStringResource("Running").resolved(in: locale)
        case .compacting:
            LocalizedStringResource("Compacting", comment: "Worktree row: the agent is compacting its context").resolved(in: locale)
        case .pullRequest, .uncommitted, .commits, .noChanges:
            gitFact(fact, locale: locale)
        case let .workingAfterTurn(work):
            // The rules give this fact only for work they count, so the
            // state's name stands in only for a count that names no kind.
            BackgroundWorkText.sentence(work, locale: locale)
                ?? LocalizedStringResource("Working in the background").resolved(in: locale)
        case .idle:
            LocalizedStringResource("Idle").resolved(in: locale)
        case .unknown:
            // The glyph's own name, so the line and the mark agree.
            LocalizedStringResource("Unknown").resolved(in: locale)
        }
    }

    /// A row at rest's Git fact: what is not committed, the request, the
    /// commits ahead, or that there is none of these. `make` hands only
    /// these here, so the last case is `.noChanges`.
    private static func gitFact(_ fact: SessionRowFact.Fact, locale: Locale) -> String {
        switch fact {
        case let .pullRequest(number, state, isDraft):
            pullRequest(number: number, state: state, isDraft: isDraft, locale: locale)
        case let .uncommitted(files):
            GitFactsText.uncommittedChip(files, locale: locale)
        case let .commits(count):
            GitFactsText.commitsChip(count, locale: locale)
        default:
            GitFactsText.noChanges(locale: locale)
        }
    }

    /// Returns what the second line says before `fact`: the checkout of a
    /// row the person labeled and the separator ("feat/login · "), or the
    /// checkout alone on a row whose fact only names its state
    /// (`showsFact`). It is empty for a row with no checkout beside its
    /// name, whose line is its fact alone. We keep it apart from the fact,
    /// so the line cuts the fact first and the checkout only when it does
    /// not fit by itself.
    static func lineLead(_ row: SessionSidebarModel.Row, fact: String, locale: Locale) -> String {
        guard let checkout = row.checkout?.shown else { return "" }
        return AgentStatusText.lead(checkout, before: row.showsFact ? fact : "", locale: locale)
    }

    /// Returns a row's tooltip: its whole name, which the row may cut short, the
    /// checkout a labeled row shows in full, its branch, the time since its
    /// last activity, and how many turns are unread. The branch says which
    /// worktree a row is when its name is a label or a conversation's; a
    /// row named by its branch, or one whose checkout is its branch, does
    /// not say it twice. A row waiting on a request Weir cannot answer, with its
    /// pane out of view, ends with a line saying how to answer it, since
    /// the row offers no "Answer…" for it.
    static func tooltip(for row: SessionSidebarModel.Row, lead: [String]? = nil, now: Date, locale: Locale) -> String {
        var parts = lead ?? [row.name]
        // The repository's row is named as any row is, so it says what it is.
        if case .project = row.id {
            parts.append(repositoryFolder.resolved(in: locale))
        }
        // The checkout goes in full: the line may show a folder less the
        // project's name.
        if let checkout = row.checkout?.name {
            parts.append(checkout)
        }
        if let branch = row.branch, branch != row.name,
           row.checkout.map({ branch.compare($0.name, options: .caseInsensitive) != .orderedSame }) ?? true
        {
            parts.append(branch)
        }
        if let agentSummary = row.agentSummary {
            parts.append(agentSummary)
        }
        if row.proposedCommits > 0 {
            parts.append(commitsAhead(row.proposedCommits, locale: locale))
        }
        if let lastActivity = row.lastActivity {
            parts.append(sinceLastActivity(lastActivity, now: now, locale: locale))
        }
        if row.unreadCount > 0 {
            parts.append(LocalizedStringResource(
                "\(row.unreadCount) unread turns",
                comment: "Worktree row tooltip: turns no one has read yet"
            ).resolved(in: locale))
        }
        if row.isInTmux {
            parts.append(LocalizedStringResource("Running in tmux — the session survives quitting Weir").resolved(in: locale))
        }
        if let limit = usageLimitSpoken(row.usageLimits, locale: locale, now: now) {
            parts.append(limit)
        }
        let facts = AgentStatusText.joined(parts, locale: locale)
        // A line of its own after the facts: what to do, not one more fact.
        if row.suggestsOpeningPane {
            let hint = LocalizedStringResource(
                "Open the pane to answer in the terminal",
                comment: "Worktree row tooltip: the row waits on a request Weir does not hold, answered at the agent's own prompt"
            ).resolved(in: locale)
            return facts + "\n" + hint
        }
        // Why the row is folded away, and how it comes back.
        if row.section == .other {
            return facts + "\n" + otherWorktreeHint.resolved(in: locale)
        }
        return facts
    }

    /// The commits ahead in full, where "+3 commits" does not say of
    /// what.
    private static func commitsAhead(_ count: Int, locale: Locale) -> String {
        LocalizedStringResource(
            "\(count) commits not on the default branch",
            comment: "Sidebar row tooltip and VoiceOver: commits on the row's branch that the default branch does not have"
        ).resolved(in: locale)
    }

    private static func isCommits(_ fact: SessionRowFact.Fact) -> Bool {
        if case .commits = fact {
            return true
        }
        return false
    }

    /// What the repository's row is, in its tooltip and read by VoiceOver
    /// after its name, where the row's mark says nothing.
    static let repositoryFolder = LocalizedStringResource(
        "Repository folder",
        comment: "Sidebar row tooltip and VoiceOver: the row is the project's own folder, the repository the worktrees are made from"
    )

    /// The tooltip's last line on one of the other worktrees.
    static let otherWorktreeHint = LocalizedStringResource(
        "Not among the worktrees above. Opening it adds it there.",
        comment: "Sidebar, one of the other worktrees: its tooltip says it is not a working row and opening it makes it one"
    )

    /// The scratch row's tooltip: the folder a new tab starts in, in place of
    /// the name the row shows, then the fact it has no second line to state
    /// and what any row's tooltip says. A summary of its agents states the
    /// fact, so the fact is not said twice.
    static func scratchTooltip(for row: SessionSidebarModel.Row, startFolder: URL, now: Date, locale: Locale) -> String {
        let folder = PathFormatting.abbreviateHome(startFolder.path)
        guard row.fact.glyph != .shell else {
            return tooltip(for: row, lead: [folder], now: now, locale: locale)
        }
        let fact = row.agentSummary == nil ? [current(row, now: now, locale: locale)] : []
        return tooltip(for: row, lead: [folder] + fact, now: now, locale: locale)
    }

    /// The scratch row's VoiceOver hint: the folder in words, as the tooltip's
    /// "~" would be read 「チルダ」.
    static func scratchHint(startFolder: URL, locale: Locale) -> String {
        let folder = PathFormatting.abbreviateHome(startFolder.path)
        guard folder != "~" else {
            return LocalizedStringResource(
                "Its tabs start in the home folder",
                comment: "Sidebar, VoiceOver: the scratch row, whose new tabs start in the home folder"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "Its tabs start in \(startFolder.lastPathComponent)",
            comment: "Sidebar, VoiceOver: the scratch row and the folder its new tabs start in"
        ).resolved(in: locale)
    }

    /// Returns what VoiceOver reads for a row: its state, name, the checkout
    /// a labeled row shows ("Branch feat/login"), and project, then its
    /// fact, the pull request its mark shows, its agents, and the time since
    /// it last moved. The request is read where the second line states it,
    /// and after the fact on a row whose line says something else (a stop,
    /// a wait), whose mark still shows it. A fact the line drops for the
    /// checkout is not read either: the state read first says it.
    static func spokenLabel(for row: SessionSidebarModel.Row, projectName: String?, now: Date, locale: Locale) -> String {
        var parts = [stateName(row.fact.glyph, locale: locale), row.name]
        // The checkout is read in full, as the tooltip says it.
        if let checkout = row.checkout {
            parts.append(checkoutSpoken(checkout, of: row, locale: locale))
        }
        parts.append(projectName ?? "")
        // On screen the fold line above says so; read on its own, the row does.
        if row.section == .other, let other = SidebarSectionText.title(.other) {
            parts.append(other.resolved(in: locale))
        }
        // The mark after the name, read after the place as the tooltip says
        // it.
        if row.isMainFolder {
            parts.append(repositoryFolder.resolved(in: locale))
        }
        let fact = AgentStatusText.spoken(current(row, now: now, locale: locale), locale: locale)
        if case .pullRequest = row.fact.fact {
            // The checks follow the request: on screen they are only the
            // mark's colored corner.
            parts.append(pullRequestSpoken(row, locale: locale) ?? fact)
        } else {
            // "+3 commits" is said in full below.
            if row.showsFact, !isCommits(row.fact.fact) {
                parts.append(fact)
            }
            if let pullRequest = pullRequestSpoken(row, locale: locale) {
                parts.append(pullRequest)
            }
        }
        if row.proposedCommits > 0 {
            parts.append(commitsAhead(row.proposedCommits, locale: locale))
        }
        // A shell's state is already "Shell"; its agent would say it again.
        if row.fact.glyph != .shell {
            parts += row.agentKinds.map { agentName(.agent($0), locale: locale) }
        }
        // The chip carries the limit only on screen; a row held by another
        // agent's limit says so nowhere else.
        if let limit = usageLimitSpoken(row.usageLimits, locale: locale, now: now) {
            parts.append(AgentStatusText.spoken(limit, locale: locale))
        }
        if let lastActivity = row.lastActivity {
            parts.append(sinceLastActivity(lastActivity, now: now, locale: locale))
        }
        return AgentStatusText.spokenList(parts, locale: locale)
    }

    /// Returns the checkout a labeled row shows, as VoiceOver reads it:
    /// said to be the branch ("Branch feat/login"), the worktree's folder
    /// ("Worktree login-redesign"), or the project's own folder ("Folder
    /// weir"), so the bare name is not taken for a second label.
    private static func checkoutSpoken(_ checkout: RowCheckout, of row: SessionSidebarModel.Row, locale: Locale) -> String {
        let name = checkout.name
        if checkout.isBranch {
            return LocalizedStringResource(
                "Branch \(name)",
                comment: "Sidebar, VoiceOver: the row's branch, read after the label the person gave its row"
            ).resolved(in: locale)
        }
        if case .project = row.id {
            return LocalizedStringResource(
                "Folder \(name)",
                comment: "Sidebar, VoiceOver: the project's own folder, read after the label the person gave a row with no branch"
            ).resolved(in: locale)
        }
        return LocalizedStringResource(
            "Worktree \(name)",
            comment: "Sidebar, VoiceOver: the worktree's folder, read after the label the person gave a row with no branch"
        ).resolved(in: locale)
    }

    /// The time since the row's last activity in whole minutes, for the
    /// tooltip and VoiceOver, where the row's column has no room.
    private static func sinceLastActivity(_ date: Date, now: Date, locale: Locale) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        return LocalizedStringResource(
            "\(minutes) min since last activity",
            comment: "Worktree row tooltip: minutes since an agent in the row last moved"
        ).resolved(in: locale)
    }

    /// The row's state as VoiceOver names it beside something else (the
    /// worktree dropdown's checkout): the glyph's name, then the pull
    /// request its mark shows, with its checks ("Idle, PR #128, Open,
    /// Checks passed, 4 of 4"), as the sidebar reads that row.
    static func spokenState(_ row: SessionSidebarModel.Row, locale: Locale) -> String {
        let state = stateName(row.fact.glyph, locale: locale)
        guard let pullRequest = pullRequestSpoken(row, locale: locale) else { return state }
        return AgentStatusText.spokenList([state, pullRequest], locale: locale)
    }

    /// The request the row's mark shows and its state, then its checks
    /// when they are known ("PR #128, Open, Checks passed, 4 of 4", the
    /// card's words read as a list); `nil` for a row with none.
    static func pullRequestSpoken(_ row: SessionSidebarModel.Row, locale: Locale) -> String? {
        row.pullRequestText.map {
            AgentStatusText.spokenList([AgentStatusText.spoken($0, locale: locale), row.checksText ?? ""], locale: locale)
        }
    }

    /// "PR #128 · Open", for a row's pull request.
    static func pullRequest(_ request: SessionRowFact.PullRequest, locale: Locale) -> String {
        pullRequest(number: request.number, state: request.state, isDraft: request.isDraft, locale: locale)
    }

    /// The state's name, as the glyph's own label reads it.
    static func stateName(_ glyph: SessionRowFact.Glyph, locale: Locale) -> String {
        let name: LocalizedStringResource = switch glyph {
        case .needsAnswer: "Needs answer"
        case .needsApproval: "Needs approval"
        case .needsResponse: "Needs response"
        case .needsSignIn: "Needs sign-in"
        case .stopped: "Stopped"
        case .unread: "Unread"
        case .unreadWorkingAfterTurn: "Unread, working in the background"
        case .running: "Running"
        case .idle: "Idle"
        case .workingAfterTurn: "Working in the background"
        case .unknown: "Unknown"
        case .shell: "Shell"
        }
        return name.resolved(in: locale)
    }

    /// The usage limit chip of a row, of the limit holding its
    /// agents at `now` (`UsageLimit.holding`): "Limit · 3:40 PM", or
    /// "Limit" when the reset is not known. `nil` once every known reset
    /// has passed: the chip says the agents are held, which they are not
    /// any longer (the stopped agent's own row still says it stopped).
    static func usageLimitChip(_ limits: [UsageLimit], locale: Locale, now: Date) -> String? {
        guard let limit = UsageLimit.holding(limits, at: now) else { return nil }
        guard let resetAt = limit.resetAt else {
            return LocalizedStringResource(
                "Limit",
                comment: "Worktree row chip: an agent in the row is at its plan's usage limit"
            ).resolved(in: locale)
        }
        guard resetAt > now else { return nil }
        return LocalizedStringResource(
            "Limit · \(StopReasonText.resetTime(resetAt, locale: locale, now: now))",
            comment: "Worktree row chip: an agent in the row is at its plan's usage limit, and when it resets"
        ).resolved(in: locale)
    }

    /// The chip as VoiceOver and the tooltip say it: the limit in full.
    static func usageLimitSpoken(_ limits: [UsageLimit], locale: Locale, now: Date) -> String? {
        UsageLimit.holding(limits, at: now).map { StopReasonText.usageLimit($0, locale: locale, now: now) }
    }

    /// A row's line (`make(_:locale:)`), which names the agent it is about
    /// while the row has more than one kind ("Codex · Needs approval"): the
    /// badges beside it say who is there, not whose line this is. A Git fact
    /// is the folder's, whoever runs in it, and names none.
    static func make(_ row: SessionRowFact, agentKinds: [AgentKind], locale: Locale) -> String {
        let text = make(row.fact, locale: locale)
        guard agentKinds.count > 1, case .agent = row.badge else { return text }
        switch row.fact {
        case .question, .approval, .prompt, .stopped, .unread, .running, .compacting, .workingAfterTurn:
            return AgentStatusText.joined([agentName(row.badge, locale: locale), text], locale: locale)
        case .pullRequest, .uncommitted, .commits, .noChanges, .idle, .unknown:
            return text
        }
    }

    /// One line per agent, as one text ("Claude · Running / Codex · Idle"). A
    /// slash between them, as a line may hold a dot of its own.
    static func agentList(_ lines: [String], locale: Locale) -> String {
        lines.dropFirst().reduce(lines.first ?? "") { text, line in
            LocalizedStringResource(
                "\(text) / \(line)",
                comment: "A row's tooltip and an Open Tabs line: separates one agent's words from the next"
            ).resolved(in: locale)
        }
    }

    /// The agent's name in full, for VoiceOver and the tooltip.
    static func agentName(_ badge: SessionRowFact.Badge, locale: Locale) -> String {
        switch badge {
        // Product names, the same in every language.
        case .agent(.claude): "Claude"
        case .agent(.codex): "Codex"
        case .shell: LocalizedStringResource("Shell").resolved(in: locale)
        }
    }

    /// The time since the last activity on the row's first line, in the
    /// largest whole unit ("12m", "3h", "2d"; 「12分」「3時間」「2日」), in
    /// the units a turn card's duration has (`CompactTimeText`), so the two
    /// read as one rule beside each other. Under a minute it is "now":
    /// counting seconds would redraw the column every second. Rounded
    /// down, as the tooltip's minutes are: 12m 40s is "12m", and 59m 30s
    /// is not yet an hour.
    static func elapsed(since date: Date, now: Date, locale: Locale) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 {
            return CompactTimeText.days(days, locale: locale)
        }
        if hours > 0 {
            return CompactTimeText.hours(hours, locale: locale)
        }
        if minutes > 0 {
            return CompactTimeText.minutes(minutes, locale: locale)
        }
        return CompactTimeText.now(locale: locale)
    }

    /// Where the command sits in an approval's second line ("Waiting for
    /// approval: swift test"), so the row sets it in the monospaced face a
    /// command has; `nil` for any other fact, and for an approval whose
    /// text is an edit's summary or a tool's name. Found in the worded
    /// line, so it holds in whatever order a language puts the words.
    static func commandRange(in text: String, for row: SessionSidebarModel.Row) -> Range<String.Index>? {
        guard row.isFactCommand else { return nil }
        let command: String? = switch row.fact.fact {
        case let .approval(command): command
        case let .prompt(.approval(approval)) where approval.action == .command: approval.subject
        default: nil
        }
        guard let command, !command.isEmpty else { return nil }
        return text.range(of: command, options: .backwards)
    }

    /// The row's agent badge: a fixed two-letter name. A shell has no
    /// badge (`SessionAgentBadge`): its glyph is the terminal's mark.
    static func badge(_ badge: SessionRowFact.Badge, locale _: Locale) -> String {
        switch badge {
        // Abbreviations of product names, the same in every language.
        case .agent(.claude): "Cl"
        case .agent(.codex): "Cx"
        case .shell: ""
        }
    }

    /// "Unread", with what the turns changed: files changed, or an answer
    /// only. Turns whose changes are not known yet, or could not be read,
    /// say only that they are unread.
    private static func unread(_ changes: ChangeSummary, locale: Locale) -> String {
        switch changes {
        case let .changed(files, _, _):
            LocalizedStringResource(
                "Unread · \(files) files changed",
                comment: "Worktree row: an unread turn and how many files it changed"
            ).resolved(in: locale)
        case .unchanged:
            LocalizedStringResource("Unread · No file changes", comment: "Worktree row: an unread turn that changed no files")
                .resolved(in: locale)
        case .unknown, .pending, .unavailable:
            LocalizedStringResource("Unread").resolved(in: locale)
        }
    }

    private static func pullRequest(number: Int, state: PRState, isDraft: Bool, locale: Locale) -> String {
        let resource = switch state {
        case .open where isDraft:
            LocalizedStringResource("PR #\(number) · Draft", comment: "Worktree row: the branch's pull request is a draft")
        case .open:
            LocalizedStringResource("PR #\(number) · Open", comment: "Worktree row: the branch's pull request is open")
        case .merged:
            LocalizedStringResource("PR #\(number) · Merged", comment: "Worktree row: the branch's pull request was merged")
        case .closed:
            LocalizedStringResource("PR #\(number) · Closed", comment: "Worktree row: the branch's pull request was closed")
        }
        return resource.resolved(in: locale)
    }
}
