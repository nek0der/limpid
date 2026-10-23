// DecisionBarContent.swift
// Limpid — what an agent pane's decision bar says: the item it shows, or the pane at rest.

import Foundation

/// The 32pt line under an agent's pane. It shows the one item of the
/// pane's attention it is on, or what the agent is doing when nothing waits
/// on the person, or, right after an item was handled, what became of it
/// and what ⌘J goes to next. It never answers a request itself: approvals
/// and questions are answered in the terminal or on the approval card.
struct DecisionBarContent: Equatable, Sendable {
    enum Body: Equatable, Sendable {
        /// Nothing waits on the person: what the agent is doing ("Bash:
        /// swift test"), or that it is idle.
        case summary(SessionRowFact.Fact)
        /// Nothing waits and the agent is not working: the receipt of its
        /// latest turn ("T3 · No file changes"), as the bar at rest reads.
        case lastTurn(UnreadTurn)
        /// Worded by what the request's tool does, as a wait Limpid does
        /// not hold is (`PromptWait`).
        case approval(provider: AgentKind, action: PromptApproval.Action, answer: AnswerPlace)
        case question(provider: AgentKind, answer: AnswerPlace)
        /// A wait at the agent's prompt with no request behind it: the
        /// approval or question its record says (`PromptWait`), else one
        /// we cannot name, in the agent's own words.
        case prompt(provider: AgentKind?, wait: PromptWait)
        case stopped(StopReason, resume: StopResume)
        /// "Resume Same Conversation" was pressed; the stop waits for its
        /// conversation to be back.
        case resuming(provider: AgentKind?)
        /// Unread turns: their receipt, or for an episode no turn record
        /// stands for, only that it finished.
        case unread(UnreadTurn)
        /// Right after an item was handled: what happened, and the item ⌘J
        /// goes to next, `nil` when nothing else needs attention.
        case done(DoneResult, next: AttentionItemID?)
    }

    /// Where a request is answered, and the time left while Limpid holds it.
    enum AnswerPlace: Equatable, Sendable {
        /// Limpid still holds it, as while VoiceOver runs or after a failed
        /// send: the provider's prompt is not on screen, so the card is
        /// where to answer.
        case card(heldUntil: ServiceDeadline?)
        /// Handed to the provider's own prompt, whose deadline Limpid
        /// cannot read.
        case terminal
        /// Limpid's time ran out; the person answers again in the terminal.
        case terminalAfterTimeout
        /// The person's decision is on its way from the card or the menu
        /// bar; there is nothing to answer until it lands.
        case sending
    }

    enum DoneResult: Equatable, Sendable {
        /// A request handed to the terminal was answered there.
        case answeredInTerminal
        /// A question or permission prompt at the terminal was declined
        /// there (Esc at Claude's prompt), which stopped the turn.
        case declinedInTerminal
        /// The person marked the pane's turns viewed; the line offers Undo.
        case markedViewed(ViewedLineUndo)
        /// The review's comments were inserted into the input of the
        /// pane's agent; Return sends them.
        case insertedReview(agent: AgentKind)
        /// The stopped conversation is back after "Resume Same
        /// Conversation".
        case resumed
        /// The code went back to the start of a turn; the line
        /// offers "Undo Restore".
        case restored(RestoreDone)

        /// Whether this is the line after the restore `opID`.
        func restores(_ opID: String) -> Bool {
            if case let .restored(done) = self {
                done.opID == opID
            } else {
                false
            }
        }

        /// Whether the line shows over the pane's unread turns: the
        /// comments wait in the input while the turn they are about still
        /// waits to be marked viewed. Never over a request, a prompt for
        /// input, or a stop, where Return would answer what is on screen
        /// (`shows(_:over:)`).
        var showsOverItems: Bool {
            switch self {
            // The resumed conversation's unread turns come back to the list
            // with it, under the line that says it is back.
            case .insertedReview, .resumed: true
            case .answeredInTerminal, .declinedInTerminal, .markedViewed, .restored: false
            }
        }
    }

    /// The item's place among the pane's items in the order they arrived
    /// ("1 / 2"), the order the Needs Attention list has them in, and the
    /// kind of a higher-ranked one the bar is not on ("Approval also
    /// pending"). `nil` while the pane has one item or none.
    struct Position: Equatable, Sendable {
        let index: Int
        let count: Int
        let higherKind: AlsoPending?
    }

    /// Whether a stop can be resumed in its conversation.
    enum StopResume: Equatable, Sendable {
        /// No session id to resume by, or the agent is still in front of
        /// its terminal, where the person carries on in the TUI.
        case unavailable
        case available
        case resuming
        /// The last resume did not bring the conversation back; it can be
        /// tried again.
        case failed
        /// It could be resumed, but not from what the pane shows now.
        case blocked(ResumeBlocker)
    }

    /// Why a resume is not typed now.
    enum ResumeBlocker: Equatable, Sendable {
        /// Something other than the shell is in front: an editor, a pager,
        /// a REPL, ssh, where the resume would be keys to that program.
        case notAtShell
        /// Text is half typed at the shell's prompt; the resume would run
        /// on from it.
        case draft
    }

    enum AlsoPending: Equatable, Sendable {
        case approval
        case question
        /// A wait at the agent's prompt we cannot name as either.
        case response
        case stop
    }

    let body: Body
    let position: Position?
    /// The item shown, so a press acts on it and nothing else.
    let itemID: AttentionItemID?

    /// What decides the bar of one pane.
    struct Input: Sendable {
        /// The pane's attention items.
        var items: [AttentionItem] = []
        /// The item chosen for this pane, from the bar's count button, the
        /// Needs Attention list, or ⌘J; the highest-ranked otherwise.
        var selected: AttentionItemID?
        /// The pane's agent, for its summary at rest.
        var agent: SessionRowFact.Agent?
        /// What each approval's tool does. One not here reads as a tool
        /// that neither changes files nor runs a command: nothing says it
        /// does either.
        var approvalActions: [ApprovalKey: PromptApproval.Action] = [:]
        /// What was just handled in this pane, while the bar still says so.
        var done: Done?
        /// The agent's latest ended turn, for the bar at rest.
        var lastTurn: UnreadTurn?
        /// How each of the pane's stops can be resumed; one not here
        /// cannot.
        var stopResumes: [AttentionItemID: StopResume] = [:]
    }

    struct Done: Equatable, Sendable {
        let result: DoneResult
        let next: AttentionItemID?
    }

    static func make(_ input: Input) -> DecisionBarContent {
        // A turn that only answered is no item for the bar: opening the pane
        // reads it, and the bar at rest already gives its receipt.
        let arrived = arrivalOrder(input.items.filter { !isAnswerOnly($0) })
        if let done = input.done, input.selected == nil, shows(done.result, over: arrived) {
            return DecisionBarContent(body: .done(done.result, next: done.next), position: nil, itemID: nil)
        }
        guard let shown = arrived.first(where: { $0.id == input.selected }) ?? PanePriority.dominant(arrived) else {
            if let done = input.done {
                return DecisionBarContent(body: .done(done.result, next: done.next), position: nil, itemID: nil)
            }
            if let lastTurn = input.lastTurn, isAtRest(input.agent) {
                return DecisionBarContent(body: .lastTurn(lastTurn), position: nil, itemID: nil)
            }
            return DecisionBarContent(body: .summary(summary(of: input.agent)), position: nil, itemID: nil)
        }
        return DecisionBarContent(
            body: body(of: shown, approvalActions: input.approvalActions, resume: input.stopResumes[shown.id] ?? .unavailable),
            position: position(of: shown, in: arrived),
            itemID: shown.id
        )
    }

    /// The pane's item after `current` for the count button, in the order
    /// they arrived, wrapping.
    static func next(after current: AttentionItemID?, in items: [AttentionItem]) -> AttentionItemID? {
        let arrived = arrivalOrder(items.filter { !isAnswerOnly($0) })
        guard let index = arrived.firstIndex(where: { $0.id == current }) else { return arrived.first?.id }
        return arrived[(index + 1) % arrived.count].id
    }

    /// Whether the bar of a pane with `items` takes a "Done" left for it
    /// (by the review tab): with nothing waiting, or one that shows over
    /// what waits.
    static func takes(_ result: DoneResult, over items: [AttentionItem]) -> Bool {
        items.isEmpty || shows(result, over: items)
    }

    /// Whether `result` shows over `items`: one that may (an insert's
    /// line), over unread turns only. A request, a prompt for input
    /// (often a permission the terminal asks itself), and a stop each wait
    /// for an answer Return would give.
    static func shows(_ result: DoneResult, over items: [AttentionItem]) -> Bool {
        guard result.showsOverItems else { return false }
        return items.allSatisfy { item in
            if case .unread = item.kind {
                true
            } else {
                false
            }
        }
    }

    private static func isAnswerOnly(_ item: AttentionItem) -> Bool {
        guard case let .unread(turn) = item.kind else { return false }
        return turn.changes == .unchanged
    }

    /// The agent waits for the next prompt, so what it last did is what the
    /// bar has to say. While it works, what it is doing says more.
    private static func isAtRest(_ agent: SessionRowFact.Agent?) -> Bool {
        switch agent?.state {
        case .finished, .idle: true
        default: false
        }
    }

    private static func arrivalOrder(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted { $0.arrivalSequence < $1.arrivalSequence }
    }

    private static func body(
        of item: AttentionItem,
        approvalActions: [ApprovalKey: PromptApproval.Action],
        resume: StopResume
    ) -> Body {
        switch item.kind {
        case let .approval(fact):
            .approval(provider: fact.provider, action: approvalActions[fact.key] ?? .other, answer: answerPlace(of: fact))
        case let .question(fact):
            .question(provider: fact.provider, answer: answerPlace(of: fact))
        case let .prompt(wait):
            .prompt(provider: item.subject.provider, wait: wait)
        case .stop where resume == .resuming:
            .resuming(provider: item.subject.provider)
        case let .stop(reason):
            .stopped(reason, resume: resume)
        case let .unread(turn):
            .unread(turn)
        }
    }

    private static func answerPlace(of fact: ApprovalFact) -> AnswerPlace {
        switch fact.state {
        // Being handed to the terminal: its prompt is about to appear.
        case .sending(.delegate, _):
            .terminal
        case .sending:
            .sending
        case .held, .sendFailed:
            .card(heldUntil: fact.deadline)
        case .timedOut:
            .terminalAfterTimeout
        case .handedToTerminal, .withdrawn, .unknownResult, .answered:
            .terminal
        }
    }

    private static func position(of shown: AttentionItem, in arrived: [AttentionItem]) -> Position? {
        guard arrived.count > 1, let index = arrived.firstIndex(where: { $0.id == shown.id }) else { return nil }
        let higher = PanePriority.dominant(arrived.filter { PanePriority.outranks($0.kind, shown.kind) })
        return Position(index: index + 1, count: arrived.count, higherKind: higher.flatMap { alsoPending($0.kind) })
    }

    private static func alsoPending(_ kind: AttentionItemKind) -> AlsoPending? {
        switch kind {
        // A wait at the prompt is named as its row names it: the approval
        // or question its record says, else a response.
        case .approval, .prompt(.approval): .approval
        case .prompt(.unclassified): .response
        case .question, .prompt(.question): .question
        case .stop: .stop
        case .unread: nil
        }
    }

    private static func summary(of agent: SessionRowFact.Agent?) -> SessionRowFact.Fact {
        SessionRowFact.make(.init(agents: agent.map { [$0] } ?? [])).fact
    }
}

/// A restore the bar's "Done" line names and offers to undo.
struct RestoreDone: Equatable, Sendable {
    let opID: String
    /// The worktree, as the restore's journal names it.
    let root: String
    /// `nil` for a journal from a build that did not name the turn.
    let turnNumber: Int?
}
