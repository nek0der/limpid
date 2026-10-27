// SessionRowFact.swift
// Limpid — what one sidebar session row says: its state, its one fact, and whose fact it is.

import Foundation

/// A session row's state glyph, the single fact on its second line, the
/// agent that fact is about, and the pull request attached to it. One row stands for one place to
/// work (the project's folder or a worktree) and every pane in it, so the
/// row shows the agent that most needs the person, in one order for the
/// whole app: a question or an approval, then a stop, a running turn, an
/// unread turn, and last the row at rest.
struct SessionRowFact: Equatable, Sendable {
    enum Glyph: Equatable, Sendable {
        case needsAnswer
        case needsApproval
        /// A wait at the agent's prompt we cannot name as an approval or a
        /// question: the state's own neutral name ("Needs response"). It ranks with
        /// approvals.
        case needsResponse
        case stopped
        case unread
        case running
        case idle
        case unknown
        /// A row with no agent, only shells: it has no state to show.
        case shell
    }

    enum Fact: Equatable, Sendable {
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
    /// second line drops such a fact for the folder, which says more. The
    /// project's folder row's "Folder" at rest is `.idle`'s, so it goes
    /// too: the folder's name says it better.
    static func repeatsGlyph(_ fact: Fact) -> Bool {
        switch fact {
        case .idle, .unknown, .running(nil), .question(nil), .approval(nil):
            true
        case let .prompt(wait):
            switch wait {
            case let .approval(approval): approval.fact == nil
            case let .question(detail), let .unclassified(detail): detail == nil
            }
        case let .stopped(.error(text)):
            text?.isEmpty ?? true
        case .unread(.unknown), .unread(.pending), .unread(.unavailable):
            true
        case .running(.some), .question(.some), .approval(.some), .stopped, .unread, .compacting,
             .pullRequest, .uncommitted, .commits:
            false
        }
    }

    /// Whose fact the second line states: an agent, or a shell when the row
    /// has no agent.
    enum Badge: Equatable, Sendable {
        case agent(AgentKind)
        case shell
    }

    /// The row's state, and only its state: never the pull request.
    let glyph: Glyph
    let fact: Fact
    let badge: Badge
    /// The pull request on the row's branch, which the row shows as a mark
    /// beside its badge whatever its state: the left of a row
    /// says its state, the right what is attached to it, so a stopped or
    /// waiting row still shows its request. `nil` when it has none.
    var pullRequest: PullRequest?

    /// One agent running in the row.
    struct Agent: Equatable, Sendable {
        let provider: AgentKind
        let state: AgentState
        /// What it reported last: the tool it runs, or its message.
        let detail: String?
    }

    /// A pull request on the row's branch.
    struct PullRequest: Equatable, Sendable {
        let number: Int
        let state: PRState
        let isDraft: Bool
    }

    /// What decides a row.
    struct Input: Sendable {
        /// The attention items of the row's panes.
        var items: [AttentionItem] = []
        /// What the list shows of a request: the question's start, or the
        /// command. Missing when the ledger no longer holds it.
        var requestText: [ApprovalKey: String] = [:]
        var agents: [Agent] = []
        var pullRequest: PullRequest?
        /// The folder's files changed and not committed, and the commits a
        /// pull request from it would carry (`GitFacts`); 0 when not known.
        var uncommittedFiles = 0
        var proposedCommits = 0
    }

    /// The agent a row with no attention item speaks for: the first one
    /// running a turn, else the first. `nil` for a row with none.
    static func leadAgentIndex(of states: [AgentState]) -> Int? {
        states.firstIndex { $0 == .running || $0 == .compacting } ?? (states.isEmpty ? nil : 0)
    }

    static func make(_ input: Input) -> Self {
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
        if let index = leadAgentIndex(of: input.agents.map(\.state)),
           input.agents[index].state == .running || input.agents[index].state == .compacting
        {
            let agent = input.agents[index]
            return Self(
                glyph: .running,
                fact: agent.state == .compacting ? .compacting : .running(agent.detail.flatMap { $0.isEmpty ? nil : $0 }),
                badge: .agent(agent.provider)
            )
        }
        if let item = PanePriority.dominant(input.items.filter(isUnread)) {
            return fact(for: item, requestText: input.requestText)
        }
        // At rest, the second line states a Git fact when there is one,
        // whatever runs in the row: the pull request, else what is
        // not committed, else what is committed and not on the default
        // branch.
        let repositoryFact: Fact? = if let request = input.pullRequest {
            .pullRequest(number: request.number, state: request.state, isDraft: request.isDraft)
        } else if input.uncommittedFiles > 0 {
            .uncommitted(files: input.uncommittedFiles)
        } else if input.proposedCommits > 0 {
            .commits(input.proposedCommits)
        } else {
            nil
        }
        guard let first = input.agents.first else {
            return Self(glyph: .shell, fact: repositoryFact ?? .idle, badge: .shell)
        }
        // Not matched to its hook yet (an agent just started, or a run just
        // after a relaunch): the row says so rather than claiming to be at
        // rest, in its glyph and, with no Git fact, in its line.
        if input.agents.allSatisfy({ $0.state == .unknown }) {
            return Self(glyph: .unknown, fact: repositoryFact ?? .unknown, badge: .agent(first.provider))
        }
        return Self(glyph: .idle, fact: repositoryFact ?? .idle, badge: .agent(first.provider))
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
    static func glyph(of kind: AttentionItemKind) -> Glyph {
        switch kind {
        case .question, .prompt(.question): .needsAnswer
        case .approval, .prompt(.approval): .needsApproval
        case .prompt(.unclassified): .needsResponse
        case .stop: .stopped
        case .unread: .unread
        }
    }
}
