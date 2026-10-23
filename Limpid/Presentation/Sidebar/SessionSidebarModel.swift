// SessionSidebarModel.swift
// Limpid — one project's rows in the supervision sidebar, and the scratch row's state.

import Foundation

/// One project's rows in the sidebar, under its header
/// (`SidebarListModel`): a row for each place to work in the project, each
/// in the same two-line form. The working rows come first (the worktrees in the order they were
/// made, then the folder), then a line for the worktrees ready to clean up
/// and one for the other worktrees, each with its rows under it while it is
/// open (`SidebarPresentedSections`). Rows are never sorted by state; the
/// state is what the row shows.
struct SessionSidebarModel: Equatable {
    /// How a row's second line is colored. Color is never the only sign:
    /// the glyph and the words carry the same meaning.
    enum Tone: Equatable {
        case waiting
        case stopped
        case muted
    }

    struct Row: Identifiable, Equatable {
        let id: ContainerID
        let name: String
        /// Where `name` is cut when it does not fit (`RowInput.nameTruncation`):
        /// the sidebar, the session header, and all projects' cards cut it
        /// the same way.
        let nameTruncation: SupervisionTruncation
        let fact: SessionRowFact
        let factText: String
        let tone: Tone
        /// "Cl" or "Cx"; empty for a shell, which has no badge.
        let badgeText: String
        /// When an agent in the row last moved; `nil` for a row with no
        /// agent, which then shows no time.
        let lastActivity: Date?
        let isActive: Bool
        /// The project's own folder: it cannot be hidden from the sidebar
        /// or deleted as a worktree.
        let isMainFolder: Bool
        /// The worktree's folder is gone from disk.
        let isMissing: Bool
        /// The section the row is listed in (`SidebarPresentedSections`).
        var section: SidebarSection = .working
        /// The request "Answer…" opens, while Limpid can still answer it.
        let answerKey: ApprovalKey?
        /// Unread turns across the row's agents, for its tooltip.
        let unreadCount: Int
        /// Each agent's own fact ("Claude: Unread / Codex: Idle"), for the
        /// tooltip of a row with more than one; `nil` for one or none.
        let agentSummary: String?
        /// The pull request's checks in words for VoiceOver only ("Checks passed, 4 of 4"), read
        /// out with the request: on screen a failing check is only a red
        /// badge on its mark.
        let checksText: String?
        /// The pull request the row's mark shows, in words ("PR #128 ·
        /// Open"), for VoiceOver and the header's tooltip; `nil` for a row
        /// with none (`SessionRowFact.pullRequest`).
        var pullRequestText: String?
        /// An agent in the row runs inside tmux, so it outlives Limpid.
        let isInTmux: Bool
        /// The item the row shows (`PanePriority.dominant`), which opening
        /// the row from elsewhere goes to; `nil` when it shows none.
        let leadItemID: AttentionItemID?
        /// The pane the row's fact is about: the lead item's, else the
        /// first agent's, else the focused pane of the row's first tab;
        /// `nil` for a row with no tab.
        let leadPaneID: UUID?
        /// The row has a tab: a session rather than a folder with nothing
        /// open.
        let hasTabs: Bool
        /// The account-wide usage limits of the row's agents. The view
        /// picks the one holding them against its clock
        /// (`UsageLimit.holding`), so the chip goes once they reset.
        var usageLimits: [UsageLimit] = []
        /// The branch of the row's folder, for its tooltip; `nil` when not
        /// known.
        var branch: String?
        /// This is the folder the row's second line starts with, for a row
        /// named by the person, whose name no longer says which worktree it
        /// is (`WorkspaceSession.rowFolder(of:)`). It is `nil` for any other row.
        var folder: RowFolder?
        /// How many agents run in the row.
        var agentCount = 0
        /// The second line states an approval's command, rather than an
        /// edit's summary or a tool's name.
        var isFactCommand = false
        /// The item the row shows is answered at the agent's own prompt
        /// (`AttentionItem.requiresTerminalAnswer`): the row offers no
        /// "Answer…", and unless its pane is in view, its tooltip says
        /// that opening the pane is how to answer, since choosing the row
        /// goes there.
        var requiresTerminalAnswer = false
        /// The row is the window's active one and its lead pane is in the
        /// tab the window shows: the person already sees the prompt, so the
        /// tooltip does not send them there.
        var isLeadPaneShown = false

        /// Whether the second line states the row's fact. A row that
        /// starts the line with its folder drops a fact that only names the
        /// state its glyph shows (`SessionRowFact.repeatsGlyph`), and shows
        /// the folder alone.
        var showsFact: Bool {
            folder == nil || !SessionRowFact.repeatsGlyph(fact.fact)
        }

        /// Whether the tooltip says to open the pane to answer in the
        /// terminal.
        var suggestsOpeningPane: Bool {
            requiresTerminalAnswer && !isLeadPaneShown
        }
    }

    /// One of the two lists that fold into a line: how many rows it
    /// holds, and whether the window has it open. A folded one's rows are not
    /// built: a project with dozens of agent worktrees costs a count.
    struct Fold: Identifiable, Equatable {
        /// The project whose rows it holds: every project of the sidebar
        /// has its own two.
        let projectID: UUID
        let section: SidebarSection
        let count: Int
        let isOpen: Bool

        var id: SidebarItemID {
            .fold(projectID, section)
        }
    }

    /// One line of the list, in the order the sidebar draws them.
    enum Item: Identifiable, Equatable {
        case row(Row)
        case fold(Fold)

        var id: SidebarItemID {
            switch self {
            case let .row(row): .row(row.id)
            case let .fold(fold): fold.id
            }
        }
    }

    /// The rows built, in the order they are listed: the working rows, then
    /// the rows of each open fold.
    let rows: [Row]
    /// The rows and the fold lines together, as the sidebar draws them.
    let items: [Item]

    /// The containers the sidebar lists for `project`, in its order: the
    /// project's folder first, then its worktrees the sidebar shows.
    static func containers(of project: Project) -> [ContainerID] {
        [.project(project.id)] + project.worktrees
            .filter { !$0.isHidden }
            .map { .worktree(projectID: project.id, worktreeID: $0.id) }
    }

    /// What one row is built from, looked up by whoever holds the session.
    struct RowInput {
        let container: ContainerID
        let name: String
        /// Where `name` is cut when it does not fit: a known branch in its
        /// middle, any other name at its end. Required, so a new source of
        /// rows cannot forget to say.
        let nameTruncation: SupervisionTruncation
        let fact: SessionRowFact.Input
        let lastActivity: Date?
        let isMissing: Bool
        /// The section the row is listed in.
        var section: SidebarSection = .working
        /// One input per agent in the row, each with only its own items.
        var agents: [SessionRowFact.Input] = []
        var isInTmux = false
        /// The checks of the row's pull request and the forge that names
        /// them.
        var pullRequestChecks: (checks: PRChecks, forge: ForgeKind)?
        var leadPaneID: UUID?
        var hasTabs = false
        var branch: String?
        /// This is the folder shown beside a name the person gave
        /// (`WorkspaceSession.rowFolder(of:)`).
        var folder: RowFolder?
        /// The approvals whose text is a command to run
        /// (`ApprovalRequestText.isCommand`).
        var commandRequests: Set<ApprovalKey> = []
    }

    /// `usageLimits` holds each provider's agents at its limit: every row
    /// with one of them shows the chip, not only the row that stopped.
    /// `activeContainer` `nil` marks no row active: the window asked for is
    /// not one the session knows. `shownPanes` are the panes of the tab the
    /// window shows.
    init(
        rows inputs: [RowInput],
        activeContainer: ContainerID?,
        shownPanes: Set<UUID> = [],
        usageLimits: UsageLimits,
        locale: Locale,
        folds: [Fold] = []
    ) {
        let rows = inputs.map { input in
            let fact = SessionRowFact.make(input.fact)
            let limit = Self.usageLimit(of: input, in: usageLimits)
            let isActive = input.container == activeContainer
            return Row(
                id: input.container,
                name: input.name,
                nameTruncation: input.nameTruncation,
                fact: fact,
                factText: Self.factText(fact.fact, of: input.container, locale: locale),
                tone: Self.tone(of: fact.fact),
                badgeText: SessionRowFactText.badge(fact.badge, locale: locale),
                lastActivity: input.lastActivity,
                isActive: isActive,
                isMainFolder: input.container.worktreeID == nil,
                isMissing: input.isMissing,
                section: input.section,
                answerKey: Self.answerKey(input.fact.items),
                unreadCount: input.fact.items.count {
                    if case .unread = $0.kind {
                        true
                    } else {
                        false
                    }
                },
                agentSummary: Self.agentSummary(input.agents, locale: locale),
                checksText: input.pullRequestChecks.map { PRChecksText.spoken($0.checks, forge: $0.forge, locale: locale) },
                pullRequestText: fact.pullRequest.map { SessionRowFactText.pullRequest($0, locale: locale) },
                isInTmux: input.isInTmux,
                leadItemID: PanePriority.dominant(input.fact.items)?.id,
                leadPaneID: input.leadPaneID,
                hasTabs: input.hasTabs,
                usageLimits: limit,
                branch: input.branch,
                folder: input.folder,
                agentCount: input.fact.agents.count,
                isFactCommand: Self.isFactCommand(input),
                requiresTerminalAnswer: PanePriority.dominant(input.fact.items)?.requiresTerminalAnswer ?? false,
                isLeadPaneShown: isActive && input.leadPaneID.map(shownPanes.contains) ?? false
            )
        }
        self.rows = rows
        items = rows.filter { $0.section == .working }.map(Item.row) + folds.filter { $0.count > 0 }.flatMap { fold in
            [Item.fold(fold)] + (fold.isOpen ? rows.filter { $0.section == fold.section }.map(Item.row) : [])
        }
    }

    /// Whether a row's menu offers Move to Other Worktrees: only on a
    /// working worktree Git lists, with nothing open, that the window is not
    /// on. One with a tab, and the selected row, stay working rows whatever
    /// they are admitted as, so the entry would move nothing; a pinned
    /// folder has no other list to go to.
    static func offersRemoveFromWorking(_ row: Row, worktree: Worktree, hasTabs: Bool) -> Bool {
        row.section == .working && !row.isActive && !hasTabs && !worktree.isMissing
            && worktree.origin == .gitWorktree && worktree.admission != .discovered
    }

    /// The account-wide limits of the row's agents' providers.
    private static func usageLimit(of input: RowInput, in limits: UsageLimits) -> [UsageLimit] {
        let providers = Set((input.agents.isEmpty ? [input.fact] : input.agents).flatMap { $0.agents.map(\.provider) })
        return providers.sorted { $0.rawValue < $1.rawValue }.flatMap { limits.accountWide(of: $0) }
    }

    /// "Claude: Unread · 2 files changed / Codex: Idle", when the row has
    /// more than one agent: the row itself shows only the one that most
    /// needs the person. A slash between agents, as a fact may hold a
    /// dot of its own.
    private static func agentSummary(_ agents: [SessionRowFact.Input], locale: Locale) -> String? {
        guard agents.count > 1 else { return nil }
        let lines = agents.map { input in
            let fact = SessionRowFact.make(input)
            return LocalizedStringResource(
                "\(SessionRowFactText.agentName(fact.badge, locale: locale)): \(SessionRowFactText.make(fact.fact, locale: locale))",
                comment: "Worktree row tooltip: one agent and its fact"
            ).resolved(in: locale)
        }
        return lines.dropFirst().reduce(lines[0]) { text, line in
            LocalizedStringResource(
                "\(text) / \(line)",
                comment: "Worktree row tooltip: separates one agent's fact from the next"
            ).resolved(in: locale)
        }
    }

    /// The second line. The project's folder at rest says it is the folder:
    /// it closes the working rows under a name that may be a
    /// conversation's or a branch's, like any worktree's.
    private static func factText(_ fact: SessionRowFact.Fact, of container: ContainerID, locale: Locale) -> String {
        if fact == .idle, case .project = container {
            return SessionRowFactText.folder.resolved(in: locale)
        }
        return SessionRowFactText.make(fact, locale: locale)
    }

    private static func tone(of fact: SessionRowFact.Fact) -> Tone {
        switch fact {
        case .question, .approval, .prompt: .waiting
        case .stopped: .stopped
        case .unread, .running, .compacting, .pullRequest, .uncommitted, .commits, .idle, .unknown: .muted
        }
    }

    /// The request the row offers to answer: the one it shows, when
    /// Limpid can still take a decision for it. Codex's questions are
    /// answered in the TUI, so they offer none.
    private static func answerKey(_ items: [AttentionItem]) -> ApprovalKey? {
        guard let item = PanePriority.dominant(items), item.canAnswerInLimpid else { return nil }
        switch item.kind {
        case let .approval(fact), let .question(fact): return fact.key
        case .prompt, .stop, .unread: return nil
        }
    }

    /// Whether the approval the second line states (the row's dominant
    /// item, as `SessionRowFact.make` picks it) waits on a command.
    private static func isFactCommand(_ input: RowInput) -> Bool {
        switch PanePriority.dominant(input.fact.items)?.kind {
        case let .approval(fact):
            input.commandRequests.contains(fact.key)
        // A wait Limpid does not hold names its command in the agent's own
        // words ("Bash: swift test").
        case let .prompt(.approval(approval)):
            approval.action == .command && approval.subject != nil
        default:
            false
        }
    }
}
