// SessionRowFact.swift
// Weir — what one sidebar session row says: its state, its one fact, and whose fact it is.

import Foundation

/// A session row's state glyph, the single fact on its second line, the
/// agent that fact is about, and the pull request attached to it. One row stands for one place to
/// work (the project's folder or a worktree) and every pane in it, so the
/// fact is about the agent that most needs the person, in one order for the
/// whole app: a question or an approval, then a stop, a running turn, an
/// unread turn, and last the row at rest. Work an agent left running when
/// its turn ended is not a running turn: it marks the rest it sits on, or
/// the unread turn of the run that left it (`Agent.isWorkingAfterTurn`).
package struct SessionRowFact: Equatable, Sendable {
    package enum Glyph: Equatable, Sendable {
        case needsAnswer
        case needsApproval
        /// A wait at the agent's prompt we cannot name as an approval or a
        /// question: the state's own neutral name ("Needs response"). It ranks with
        /// approvals.
        case needsResponse
        /// The agent waits for the person to sign in again. It ranks with
        /// approvals.
        case needsSignIn
        case stopped
        case unread
        /// An unread turn whose run still has work running after it
        /// (`Agent.isWorkingAfterTurn`).
        case unreadWorkingAfterTurn
        case running
        case idle
        /// A row at rest whose agent still has work running after its turn
        /// (`Agent.isWorkingAfterTurn`): nothing the person asked for is
        /// under way, but something still runs.
        case workingAfterTurn
        case unknown
        /// A row with no agent, only shells: it has no state to show.
        case shell
    }

    package enum Fact: Equatable, Sendable {
        /// The start of the question; `nil` when the request is not known.
        case question(String?)
        /// The command waiting on approval.
        case approval(String?)
        /// A wait at the agent's prompt with no request behind it: the
        /// approval or question its record says (`PromptWait`), else one
        /// we cannot name, which needs a response.
        case prompt(PromptWait)
        case stopped(StopReason)
        case unread(ChangeSummary)
        /// What the agent is doing now ("Bash: swift test").
        case running(String?)
        case compacting
        case pullRequest(number: Int, state: PRState, isDraft: Bool)
        /// Files changed and not committed.
        case uncommitted(files: Int)
        /// Commits the default branch does not have.
        case commits(Int)
        /// What a resting agent left running when its turn ended, with no
        /// Git fact to state: the line says what still runs rather than
        /// "Idle" beside the mark of work.
        case workingAfterTurn(BackgroundWork)
        /// At rest with the folder's Git facts read and nothing to state:
        /// nothing uncommitted, no commits ahead, no pull request.
        case noChanges
        /// At rest with the folder's Git facts not read yet, or not a
        /// repository: the line names the state the glyph shows, since
        /// "No changes" would claim what is not known.
        case idle
        /// An agent not matched to its hook yet, with no Git fact to state:
        /// the line names the state the glyph shows, never "Idle" beside
        /// the unknown mark.
        case unknown
    }

    /// Whether `fact` only names the state its glyph already shows, as a
    /// fact falls back to when it knows nothing more: "Idle", "Running"
    /// with no tool, a request or a stop with no words, an unread turn
    /// whose changes are not known. A row that shows its folder on its
    /// second line drops such a fact for the folder, which says more.
    package static func repeatsGlyph(_ fact: Fact) -> Bool {
        switch fact {
        case .idle, .unknown, .running(nil), .question(nil), .approval(nil):
            true
        case let .prompt(wait):
            switch wait {
            case let .approval(approval): approval.fact == nil
            case let .question(detail), let .unclassified(detail): detail == nil
            // "Needs sign-in" is all there is to say.
            case .signIn: true
            }
        case let .stopped(.error(text)):
            text?.isEmpty ?? true
        case .unread(.unknown), .unread(.pending), .unread(.unavailable):
            true
        case .running(.some), .question(.some), .approval(.some), .stopped, .unread, .compacting,
             .pullRequest, .uncommitted, .commits, .workingAfterTurn, .noChanges:
            false
        }
    }

    /// Whose fact the second line states: an agent, or a shell when the row
    /// has no agent. The row's badges show every agent in it
    /// (`SessionSidebarModel.Row.agentKinds`); this says which one the line is
    /// about.
    package enum Badge: Equatable, Sendable {
        case agent(AgentKind)
        case shell
    }

    /// The row's state, and only its state: never the pull request.
    package let glyph: Glyph
    package let fact: Fact
    package let badge: Badge
    /// The pull request on the row's branch, which the row shows as a mark
    /// beside its badge whatever its state: the left of a row
    /// says its state, the right what is attached to it, so a stopped or
    /// waiting row still shows its request. `nil` when it has none.
    package var pullRequest: PullRequest?

    /// One agent running in the row.
    package struct Agent: Equatable, Sendable {
        package let provider: AgentKind
        package let state: AgentState
        /// What it reported last: the tool it runs, or its message.
        package let detail: String?
        /// What its run left running when its turn ended
        /// (`AgentBadge.backgroundWork`); `nil` when nothing was.
        package let backgroundWork: BackgroundWork?
        /// The run it is (`AgentRuntimePresentation.id`), so an unread turn
        /// is marked with the work of its own run only; `nil` for an agent
        /// known only by its pane's badge, which no item names.
        package let runtimeID: String?

        package init(
            provider: AgentKind,
            state: AgentState,
            detail: String?,
            backgroundWork: BackgroundWork? = nil,
            runtimeID: String? = nil
        ) {
            self.provider = provider
            self.state = state
            self.detail = detail
            self.backgroundWork = backgroundWork
            self.runtimeID = runtimeID
        }

        /// Whether it runs a turn: running, or compacting.
        var isRunningATurn: Bool {
            state == .running || state == .compacting
        }

        /// Whether it rests finished with work still running that its turn
        /// left (`backgroundWork`). Only a finished run counts: the rules
        /// pass the count to the badge only then, and a run back at work is
        /// a turn, which its own mark shows. Work outside a turn (a stop
        /// hook's continuation) runs as a turn does, so it is not this.
        var isWorkingAfterTurn: Bool {
            state == .finished && !(backgroundWork?.isEmpty ?? true)
        }
    }

    /// A pull request on the row's branch.
    package struct PullRequest: Equatable, Sendable {
        package let number: Int
        package let state: PRState
        package let isDraft: Bool

        package init(
            number: Int,
            state: PRState,
            isDraft: Bool
        ) {
            self.number = number
            self.state = state
            self.isDraft = isDraft
        }
    }

    /// What decides a row.
    package struct Input: Sendable {
        /// The attention items of the row's panes.
        package var items: [AttentionItem] = []
        /// What the list shows of a request: the question's start, or the
        /// command. Missing when the ledger no longer holds it.
        package var requestText: [ApprovalKey: String] = [:]
        package var agents: [Agent] = []
        package var pullRequest: PullRequest?
        /// The folder's files changed and not committed, and the commits a
        /// pull request from it would carry (`GitFacts`); 0 when not known.
        package var uncommittedFiles = 0
        package var proposedCommits = 0
        /// The folder's Git facts have been read, so 0 above means none
        /// rather than not known.
        package var hasGitFacts = false

        package init(
            items: [AttentionItem] = [],
            requestText: [ApprovalKey: String] = [:],
            agents: [Agent] = [],
            pullRequest: PullRequest? = nil,
            uncommittedFiles: Int = 0,
            proposedCommits: Int = 0,
            hasGitFacts: Bool = false
        ) {
            self.items = items
            self.requestText = requestText
            self.agents = agents
            self.pullRequest = pullRequest
            self.uncommittedFiles = uncommittedFiles
            self.proposedCommits = proposedCommits
            self.hasGitFacts = hasGitFacts
        }
    }

    /// The agent a row with no attention item speaks for: the first one
    /// running a turn, else the first one resting with work its turn left
    /// running (`Agent.isWorkingAfterTurn`), else the first. `nil` for a row
    /// with none. That work ranks below a turn, which is what the person
    /// asked for, and above a plain rest, so the row's mark of it and the
    /// line beside it are the same agent's.
    package static func leadAgentIndex(of agents: [Agent]) -> Int? {
        agents.firstIndex(where: \.isRunningATurn)
            ?? agents.firstIndex(where: \.isWorkingAfterTurn)
            ?? (agents.isEmpty ? nil : 0)
    }

    package static func make(_ input: Input) -> Self {
        var row = state(of: input)
        row.pullRequest = input.pullRequest
        return row
    }

    /// The row's glyph, fact, and badge, without what is attached to it.
    private static func state(of input: Input) -> Self {
        // A running turn goes before an unread one. An unread turn stays
        // until its files are viewed, so ranked above the run it would hide
        // every later turn for as long as its changes sit unreviewed. Its
        // mark comes back when the running turn ends.
        let isUnread: (AttentionItem) -> Bool = { item in
            guard case .unread = item.kind else { return false }
            return true
        }
        if let item = PanePriority.dominant(input.items.filter { !isUnread($0) }) {
            return fact(for: item, requestText: input.requestText)
        }
        let lead = leadAgentIndex(of: input.agents).map { input.agents[$0] }
        if let agent = lead, agent.isRunningATurn {
            return Self(
                glyph: .running,
                fact: agent.state == .compacting ? .compacting : .running(nonEmpty(agent.detail)),
                badge: .agent(agent.provider)
            )
        }
        // No turn runs, so the lead is the first agent with work left
        // running, if any.
        let workingAfterTurn = lead.flatMap { $0.isWorkingAfterTurn ? $0 : nil }
        if let item = PanePriority.dominant(input.items.filter(isUnread)) {
            let row = fact(for: item, requestText: input.requestText)
            // Only the work of the run whose turn is unread: another run's
            // work beside it would read as this turn's.
            let isItsRunWorking = input.agents.contains { agent in
                agent.isWorkingAfterTurn && agent.runtimeID != nil && agent.runtimeID == item.subject.runtimeID
            }
            guard isItsRunWorking else { return row }
            return Self(glyph: .unreadWorkingAfterTurn, fact: row.fact, badge: row.badge)
        }
        // At rest, the second line states a Git fact when there is one,
        // whatever runs in the row: what is not committed, else the pull
        // request, else what is committed and not on the default branch.
        // What is not committed goes first because it is the one the
        // person still has to act on, and a pull request's mark stays on
        // the row while the line states the files.
        let repositoryFact: Fact? = if input.uncommittedFiles > 0 {
            .uncommitted(files: input.uncommittedFiles)
        } else if let request = input.pullRequest {
            .pullRequest(number: request.number, state: request.state, isDraft: request.isDraft)
        } else if input.proposedCommits > 0 {
            .commits(input.proposedCommits)
        } else {
            nil
        }
        // With nothing to state, a folder whose facts were read says it
        // has no changes; the glyph already says the row is at rest.
        let restFact = repositoryFact ?? (input.hasGitFacts ? .noChanges : .idle)
        guard let first = input.agents.first else {
            return Self(glyph: .shell, fact: restFact, badge: .shell)
        }
        // Not matched to its hook yet (an agent just started, or a run just
        // after a relaunch): the row says so rather than claiming to be at
        // rest, in its glyph and, with no Git fact, in its line.
        if input.agents.allSatisfy({ $0.state == .unknown }) {
            return Self(glyph: .unknown, fact: repositoryFact ?? .unknown, badge: .agent(first.provider))
        }
        // A Git fact still goes first, as at any rest; without one, the
        // line says what still runs, never "Idle" beside the mark of work.
        if let agent = workingAfterTurn, let work = agent.backgroundWork {
            return Self(glyph: .workingAfterTurn, fact: repositoryFact ?? .workingAfterTurn(work), badge: .agent(agent.provider))
        }
        return Self(glyph: .idle, fact: restFact, badge: .agent(first.provider))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        text.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func fact(for item: AttentionItem, requestText: [ApprovalKey: String]) -> Self {
        let badge: Badge = switch item.subject {
        case let .runtime(_, provider, _, _, _), let .unplaced(provider): .agent(provider)
        case .sessionRow: .shell
        }
        let fact: Fact = switch item.kind {
        case let .question(fact): .question(requestText[fact.key])
        case let .approval(fact): .approval(requestText[fact.key])
        case let .prompt(wait): .prompt(wait)
        case let .stop(reason): .stopped(reason)
        case let .unread(turn): .unread(turn.changes)
        }
        return Self(glyph: glyph(of: item.kind), fact: fact, badge: badge)
    }

    /// The glyph an item of `kind` wears, whose name every place that
    /// speaks the item says (the row, the list, the announcement): a wait
    /// at the agent's prompt is the approval or question its record says,
    /// else a wait for a response we cannot name.
    package static func glyph(of kind: AttentionItemKind) -> Glyph {
        switch kind {
        case .question, .prompt(.question): .needsAnswer
        case .approval, .prompt(.approval): .needsApproval
        case .prompt(.unclassified): .needsResponse
        case .prompt(.signIn): .needsSignIn
        case .stop: .stopped
        case .unread: .unread
        }
    }
}
