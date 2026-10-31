// ApprovalPresentationStore.swift
// Weir — transient controller projection for native agent approvals.

import Foundation
import OSLog
import WeirDomain

struct ApprovalPresentation: Identifiable, Equatable, Sendable {
    let epoch: UUID
    let runID: UUID
    let requestID: UUID
    let provider: AgentKind
    let sessionID: String?
    let operationID: String?
    let toolName: String
    let summary: String?
    let requestDescription: String?
    let inputDescription: String
    let deadlineMilliseconds: UInt64
    let questions: [ApprovalQuestion]
    /// The shell command a Bash request runs, as the agent sent it; `nil`
    /// for any other tool, whose `summary` may be a description rather than
    /// what will run. Defaulted so a request built without one (a test, a
    /// fixture) reads as no command rather than failing to compile.
    var command: String?
    /// The request's input holds a string `command`, whatever the tool.
    /// The providers take `summary` from that `command`, else from the
    /// input's `description`, so this says which of the two the summary
    /// is: a command to set in a command's face, or prose. Defaulted like
    /// `command`, reading as prose.
    var hasInputCommand = false
    /// The agent run that asked (`WEIR_AGENT_RUN_ID`, read by its hook
    /// helper), for placement only; `runID` is the helper's own session.
    /// `nil` outside a Weir run (`binding(of:)`). Defaulted like `command`.
    var agentRunID: UUID?

    /// Whether Weir can answer this request at all. It never holds a
    /// Codex question, which the TUI answers.
    var supportsNativeAnswer: Bool {
        !(provider == .codex && isQuestion)
    }

    var isQuestion: Bool {
        !questions.isEmpty
    }

    var hasQuestionTurnCompletion: Bool {
        provider == .claude && operationID?.hasPrefix(AgentQuestionTurnCompletion.operationIDPrefix) == true
    }

    var id: String {
        Self.id(epoch: epoch, runID: runID, requestID: requestID)
    }

    /// The same key the broker index can be read into before the full request
    /// is fetched.
    static func id(epoch: UUID, runID: UUID, requestID: UUID) -> String {
        "\(epoch.uuidString):\(runID.uuidString):\(requestID.uuidString)"
    }
}

@MainActor
@Observable
final class ApprovalPresentationStore {
    private nonisolated static let log = Logger.weir("agent-approval")
    private(set) var pending: [ApprovalPresentation] = []
    /// The time left on each pending request, by request, as the service's
    /// clock last reported it. Kept apart from `pending` because it is read
    /// again after the Mac wakes while the requests themselves stay the same.
    /// A request has no entry when the response carried no clock, which only
    /// a service other than the bundled one would send; the app refuses such
    /// a service, so this is a defensive case.
    private(set) var serviceDeadlines: [String: ServiceDeadline] = [:]
    /// Every request seen as pending, kept past the pending list until its
    /// turn is over, so a request that left the list is still known by how
    /// it ended.
    let ledger = ApprovalLedger()
    /// Whether the broker is close to refusing new requests, which then fall
    /// back to the provider's own prompt. Counted from the records it could
    /// not evict, not from every record it holds: consumed results stay
    /// until a slot is needed, so the full count stays at the limit.
    private(set) var isNearCapacity = false
    private(set) var resolvingIDs: Set<String> = []
    /// The request whose most recent user decision failed to reach the broker.
    /// Optional because nothing has failed yet, or a later resolve cleared it.
    private(set) var lastFailureID: String?
    /// Told each time the requests move in a way a window's card or rows
    /// follow: a request settled or left, or the store stopped. The windows
    /// keep their own cards (`WindowApprovalCard`), which the app settles
    /// here (`WindowRegistry.settleApprovalCards`). Until then nothing
    /// listens.
    @ObservationIgnored var onRequestsChanged: @MainActor () -> Void = {}
    /// When each request was first seen pending in the observed epoch. The
    /// ledger keeps the same for the requests it holds; this also covers a
    /// pending request it does not, one a stale projection lists after its
    /// episode ended.
    private var firstSeenAtByID: [String: Date] = [:]
    private var observedEpoch: UUID?
    /// Unsent answers by request. A question card can be closed (Escape or its
    /// close button) before it is sent, so its draft lives here rather than in
    /// the card's view state, and reopening the card restores it. Entries leave
    /// with their request.
    private var answerDrafts: [String: ApprovalAnswerDraft] = [:]
    /// Waits for the next deadline among the open requests. Optional
    /// because no open request may have a deadline to wait for.
    private var deadlineTask: Task<Void, Never>?
    private var observerTask: Task<Void, Never>?
    private var observerGeneration = UUID()
    /// The wake observation `refreshServiceClock(onEvery:in:)` installed,
    /// kept so installing it again replaces it and the store removes it when
    /// it goes away. Optional because it exists only once the app layer asks
    /// for it.
    private var wakeObservation: (center: NotificationCenter, token: any NSObjectProtocol)?
    /// We may miss `needsInput` between broker and runtime projections. Any
    /// active state establishes that a request preceded the next turn end.
    private(set) var observedActiveTurnIDs: Set<String> = []
    /// Scoped questions whose pane was seen running after they left the
    /// pending list, so the turn that ends next is one that followed them.
    private var activeAfterLeavingIDs: Set<String> = []
    /// Requests the broker has already accepted a decision for. The broker
    /// projection that drops them can land after the pane's turn ends, and a
    /// second decision for a settled request is rejected as already terminal,
    /// so the release path must not send one.
    private var settledIDs: Set<String> = []
    /// Requests whose background release failed, for example after a service
    /// restart changed the epoch. The release runs on every projection pass,
    /// so without this it would resend and log on each one until the request
    /// leaves.
    private var failedReleaseIDs: Set<String> = []
    /// Injected so tests can observe decisions without a live service; the
    /// default is the XPC path. A sender throws
    /// `ApprovalControllerConnection.DecisionRefusal` when the broker refused
    /// the decision because the request was already settled, and any other
    /// error for a failure the person may retry. A wrapper must not re-wrap
    /// the refusal, or it would turn into an offer to retry.
    private let decisionSender: @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
    /// Reads the service clock for the wake refresh. Injected for the same
    /// reason as `decisionSender`.
    private let serviceClockReader: @Sendable () async throws -> ApprovalControllerConnection.ServiceClockReading
    /// The agent runs as the projection last reported them, for where each
    /// request's agent is attached (`panes(for:in:)`). Set by the app, which
    /// owns `AttentionState`; until then no run is known and the session
    /// hints alone place requests.
    @ObservationIgnored var runtimes: @MainActor () -> [AgentRuntimePresentation] = { [] }

    init(
        decisionSender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
            = ApprovalControllerConnection.sendDecision,
        serviceClockReader: @escaping @Sendable () async throws -> ApprovalControllerConnection.ServiceClockReading
            = ApprovalControllerConnection.readServiceClock
    ) {
        self.decisionSender = decisionSender
        self.serviceClockReader = serviceClockReader
    }

    isolated deinit {
        if let wakeObservation {
            wakeObservation.center.removeObserver(wakeObservation.token)
        }
    }

    /// Whether the request can be answered on its card now: open (held, or
    /// after a failed send) and a kind Weir answers, which a Codex
    /// question is not. A notification or history row opens the card only
    /// then, and the pane otherwise.
    func opensCard(_ key: ApprovalKey) -> Bool {
        guard let entry = ledger.entries[key] else { return false }
        let approval = entry.presentation
        return entry.state.acceptsDecision && approval.supportsNativeAnswer
    }

    /// Whether the store follows a running approval service. While it does,
    /// a request reaches Weir through the service rather than only as the
    /// agent's own prompt.
    var isRunning: Bool {
        observerTask != nil
    }

    func start() {
        guard observerTask == nil else { return }
        let generation = UUID()
        observerGeneration = generation
        observerTask = Task { await Self.observe(store: self, generation: generation) }
    }

    func stop() {
        observerTask?.cancel()
        observerTask = nil
        observerGeneration = UUID()
        pending = []
        serviceDeadlines = [:]
        // The ledger outlives a stop (`ApprovalLedger.serviceDidStop`).
        ledger.serviceDidStop()
        isNearCapacity = false
        resolvingIDs = []
        firstSeenAtByID = [:]
        observedEpoch = nil
        // A draft lives as long as its request is known (`isKnown`).
        answerDrafts = answerDrafts.filter { isKnown($0.key) }
        deadlineTask?.cancel()
        deadlineTask = nil
        // `observedActiveTurnIDs` and `activeAfterLeavingIDs` stay with the
        // ledger they describe, whose entries end with their turn
        // (`endFinishedEpisodes`).
        settledIDs = []
        failedReleaseIDs = []
        onRequestsChanged()
    }

    func resolve(_ approval: ApprovalPresentation, _ resolution: ApprovalResolution) {
        send(resolution, for: approval, origin: .person)
    }

    /// Who sent a decision, which decides what its outcome changes.
    private enum DecisionOrigin {
        /// The person, from the card or the menu bar.
        case person
        /// Weir, after the request's turn ended without an answer.
        case release
        /// Weir, because the request's pane came into sight.
        case handOff
    }

    /// A person's decision owns the card's failure line (`lastFailureID`). A
    /// background send does not: nobody pressed anything, so its failure must
    /// not clear a failure another decision left. A failed release leaves no
    /// trace on the card; a failed hand-off leaves the request in
    /// `sendFailed`, open for the person to answer or hand over again.
    private func send(_ resolution: ApprovalResolution, for approval: ApprovalPresentation, origin: DecisionOrigin) {
        if origin == .person, let entry = ledger.entry(id: approval.id), !entry.state.acceptsDecision {
            // Sending, handed to the TUI, timed out, or settled: a second
            // decision would only be refused.
            return
        }
        guard resolvingIDs.insert(approval.id).inserted else { return }
        switch origin {
        case .person:
            if lastFailureID == approval.id {
                lastFailureID = nil
            }
            ledger.record(.userDecided(resolution), for: approval.id, now: SuspendingClock.now)
        case .handOff:
            ledger.record(.paneBecameVisible, for: approval.id, now: SuspendingClock.now)
        case .release:
            break
        }
        Task {
            do {
                try await decisionSender(approval, resolution)
                decisionWasAccepted(approval, origin: origin)
            } catch let refusal as ApprovalControllerConnection.DecisionRefusal {
                decisionWasRefused(approval, refusal, origin: origin)
            } catch {
                decisionFailed(approval, error, origin: origin)
            }
            resolvingIDs.remove(approval.id)
            ledgerDidChange()
        }
    }

    private func decisionWasAccepted(_ approval: ApprovalPresentation, origin: DecisionOrigin) {
        settledIDs.insert(approval.id)
        if origin == .release {
            // A release follows the end of the request's turn, so its
            // episode is over: there is nothing left to wait for.
            ledger.endEpisode(id: approval.id)
        } else {
            ledger.record(.sendSucceeded, for: approval.id, now: SuspendingClock.now)
        }
    }

    /// Not a failure to retry: the request was settled elsewhere.
    private func decisionWasRefused(
        _ approval: ApprovalPresentation,
        _ refusal: ApprovalControllerConnection.DecisionRefusal,
        origin: DecisionOrigin
    ) {
        settledIDs.insert(approval.id)
        switch refusal {
        case let .alreadySettled(terminal):
            ledger.settle(id: approval.id, by: terminal, now: SuspendingClock.now)
            // Only an answer beat the person's decision; a timeout, a
            // withdrawal, or a hand-off to the TUI is told as such.
            if origin == .person, case let .resolved(resolution) = terminal, resolution != .delegate {
                ledger.markAnsweredElsewhere(id: approval.id)
            }
        case .recordMissing:
            ledger.markMissing(id: approval.id, now: SuspendingClock.now)
        }
        if origin == .release {
            // As after a release that went through: the turn is over.
            ledger.endEpisode(id: approval.id)
        }
    }

    private func decisionFailed(_ approval: ApprovalPresentation, _ error: any Error, origin: DecisionOrigin) {
        Self.log.error("Approval decision failed: \(String(describing: error), privacy: .private)")
        switch origin {
        case .person:
            lastFailureID = approval.id
            ledger.record(.sendFailed(String(describing: error)), for: approval.id, now: SuspendingClock.now)
        case .handOff:
            // The request stays open for the card; the person can still
            // answer or hand it over themselves.
            ledger.record(.sendFailed(String(describing: error)), for: approval.id, now: SuspendingClock.now)
        case .release:
            failedReleaseIDs.insert(approval.id)
        }
    }

    /// Hands each held request whose pane the person can see to the TUI,
    /// where the provider's own prompt takes it. Only `held` requests go: one
    /// being sent, already handed over, timed out, or settled is left alone,
    /// and so is one whose send failed, which stays for the person rather
    /// than being retried on every change. A request whose pane nobody can
    /// see, or whose pane is unknown, is held; so is every request while
    /// VoiceOver runs (`attention`). A request's panes count only where they
    /// show the run that asked it (`shownPanes(for:in:)`): a pane attached
    /// to the run's tmux session does not while another tmux pane is in
    /// front there, even one running another agent of that session. With
    /// `holdsWhileHidden` off, every held request goes to the TUI at once.
    func handOffSeenRequests(
        attention: AttentionVisibility,
        session: WorkspaceSession,
        holdsWhileHidden: Bool
    ) {
        bindRequestsToRuns(in: session)
        for approval in pending where ledger.entry(for: approval)?.state == .held && !resolvingIDs.contains(approval.id) {
            guard !holdsWhileHidden || attention.allowsHandOff(toAnyOf: shownPanes(for: approval, in: session)) else {
                continue
            }
            send(.delegate, for: approval, origin: .handOff)
        }
    }

    /// Releases requests the terminal already answered. The helper prints
    /// nothing for `delegate`; the provider ignores it because the tool has
    /// already run, and the card and the attention item disappear with the
    /// record.
    ///
    /// We cannot correlate Claude's PermissionRequest with a tool-use ID, so
    /// we release only once the request's turn is over (`turnHasEnded`): its
    /// run reports the turn's end, or a later prompt of the run overtakes it.
    /// Other tools can restore `running` while a dialog is open; that alone
    /// proves no answer. A turn's end counts only once we saw the turn
    /// active, because a badge read before the request's own turn reached
    /// us can still show the previous turn's end; a later prompt is proof
    /// enough on its own. Only the run that asked speaks for it
    /// (`binding(of:)`): a prompt in another run of the same conversation
    /// does not end it. For a request that names no run, while it is
    /// undecided which of several runs asked, every one of them must show
    /// its turn over (`TurnStanding`). Scoped question requesters read their own
    /// turn-end receipts instead; a pane's turn end may belong to another
    /// prompt or a background agent.
    func releaseStaleApprovals(in session: WorkspaceSession) {
        bindRequestsToRuns(in: session)
        endFinishedEpisodes(in: session)
        for approval in pending {
            guard !approval.hasQuestionTurnCompletion,
                  let standing = turnStanding(for: approval, in: session)
            else { continue }
            let firstSeenAt = firstSeenAt(for: approval)
            if standing.showsTurnUnderWay(since: firstSeenAt) {
                observedActiveTurnIDs.insert(approval.id)
            }
            guard standing.hasEnded(since: firstSeenAt),
                  observedActiveTurnIDs.contains(approval.id),
                  !resolvingIDs.contains(approval.id),
                  !settledIDs.contains(approval.id),
                  !failedReleaseIDs.contains(approval.id)
            else { continue }
            send(.delegate, for: approval, origin: .release)
        }
    }

    /// Lets the ledger forget requests that left the pending list once the
    /// turn they belonged to is over (`turnHasEnded`), or once their pane is
    /// gone and there is nowhere left to show them. A request handed to the
    /// TUI, timed out, or with a lost result leaves this way: nothing
    /// reports the TUI's answer, and a "No" in Claude's dialog ends the turn
    /// with no hook, so the next prompt is often the only sign it is over.
    ///
    /// A scoped question is not ended by just any turn end of its pane,
    /// which may belong to another prompt or a background agent (the same
    /// reason the release skips it). It ends when the broker has settled it,
    /// when its pane is gone, or when a turn that ran after it left the list
    /// ends. A later prompt does not end it: the question may belong to a
    /// background agent's turn rather than the root prompt's, and such a
    /// turn outlives the prompt by design (`AgentQuestionTurnCompletion`
    /// scopes its receipt by agent for that reason), so the run's next
    /// prompt says nothing about whether that turn is over.
    private func endFinishedEpisodes(in session: WorkspaceSession) {
        let pendingIDs = Set(pending.map(\.id))
        activeAfterLeavingIDs.formIntersection(ledger.entries.values.map(\.presentation.id))
        for entry in ledger.entries.values where !pendingIDs.contains(entry.presentation.id) {
            let approval = entry.presentation
            let standing = turnStanding(for: approval, in: session)
            let isSettledScopedQuestion = approval.hasQuestionTurnCompletion && Self.scopedQuestionEnded(entry.state)
            guard let standing, !isSettledScopedQuestion else {
                // No run and no pane left to show it in, the run that asked
                // has gone, or a scoped question the broker settled: nothing
                // more will happen to it.
                end(approval)
                continue
            }
            if standing == .awaitingRun {
                // The run it names was never listed, and the broker is done
                // with it: nothing will place it now (`RunBinding.awaited`).
                if entry.hasBrokerOutcome {
                    end(approval)
                }
            } else if approval.hasQuestionTurnCompletion {
                // The pane's turn may belong to another prompt (the reason
                // the release skips these too), so only a turn that ran after
                // the question left the list, and then ended, ends it.
                if standing.isMidTurn == true {
                    activeAfterLeavingIDs.insert(approval.id)
                } else if activeAfterLeavingIDs.contains(approval.id) {
                    end(approval)
                }
            } else {
                // As the release does: a turn's end counts only once the turn
                // was seen under way, since a badge read before the request's
                // own turn reached us can still show the one before it.
                if standing.showsTurnUnderWay(since: entry.firstSeenAt) {
                    observedActiveTurnIDs.insert(approval.id)
                }
                if standing.hasEnded(since: entry.firstSeenAt), observedActiveTurnIDs.contains(approval.id) {
                    end(approval)
                }
            }
        }
    }

    /// Records that `approval`'s turn was seen under way (`noteTurnsUnderWay`).
    func noteTurnSeen(_ approval: ApprovalPresentation) {
        observedActiveTurnIDs.insert(approval.id)
    }

    private func end(_ approval: ApprovalPresentation) {
        ledger.endEpisode(id: approval.id)
        activeAfterLeavingIDs.remove(approval.id)
        observedActiveTurnIDs.remove(approval.id)
        onRequestsChanged()
    }

    /// Whether the broker has settled a scoped question for good.
    private static func scopedQuestionEnded(_ state: ApprovalRequestState) -> Bool {
        state.hasLeftTheQueue || state == .unknownResult
    }

    func answerDraft(for approval: ApprovalPresentation) -> ApprovalAnswerDraft {
        answerDrafts[approval.id] ?? ApprovalAnswerDraft()
    }

    func updateAnswerDraft(_ draft: ApprovalAnswerDraft, for approval: ApprovalPresentation) {
        guard isKnown(approval.id) else { return }
        answerDrafts[approval.id] = draft
    }

    /// The request a card showing `id` shows, while the ledger says the
    /// request still holds one open. A request the ledger does not hold has
    /// none: a pending one it does not is one whose episode ended, which a
    /// stale projection can still list. `nil` once a card for it would
    /// close (`WindowApprovalCard`).
    func approvalForCard(_ id: String) -> ApprovalPresentation? {
        guard let entry = ledger.entry(id: id), entry.holdsCardOpen else { return nil }
        return entry.presentation
    }

    /// Whether the request still has a row to point at. Rows list pending
    /// requests only; once one leaves, the rows below move up, and its last
    /// anchor marks another request's row.
    func hasRow(for approval: ApprovalPresentation) -> Bool {
        pending.contains { $0.id == approval.id }
    }

    /// Whether the store still knows `id`: pending, or kept by the ledger.
    /// Row anchors, measured heights, and drafts live as long as this does.
    func isKnown(_ id: String) -> Bool {
        ledger.entry(id: id) != nil || pending.contains { $0.id == id }
    }

    /// The ledger moved: a card may have to close, and the next deadline
    /// may be another one.
    private func ledgerDidChange() {
        onRequestsChanged()
        scheduleDeadlineCheck()
    }

    /// Times out each open request whose deadline passed on our clock, then
    /// waits for the next one.
    private func scheduleDeadlineCheck() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let nearest = checkDeadlines() else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(for: nearest, clock: .suspending)
            guard !Task.isCancelled else { return }
            self?.scheduleDeadlineCheck()
        }
    }

    /// Times out each open request whose deadline passed at `now`, and says
    /// how long until the nearest one still open; `nil` with none. Only a
    /// request with a deadline from the service clock is timed here;
    /// without one the broker's own expiry, which the projection reports,
    /// is the only timeout. Apart from the waiting, and given its `now`, so
    /// a test can check a moment without sleeping until it.
    @discardableResult
    func checkDeadlines(now: SuspendingClock.Instant = .now) -> Duration? {
        var nearest: Duration?
        for (id, deadline) in serviceDeadlines {
            guard let state = ledger.entry(id: id)?.state, state.acceptsDecision else { continue }
            let left = deadline.remaining(at: now)
            if left == .zero {
                ledger.record(.deadlinePassed, for: id, now: now)
            } else {
                nearest = min(nearest ?? left, left)
            }
        }
        return nearest
    }

    func approval(forPaneID paneID: UUID, in session: WorkspaceSession) -> ApprovalPresentation? {
        // Any pane its run is attached to, a tmux run's second one included.
        pending.first { panes(for: $0, in: session).contains { $0.paneID == paneID } }
    }

    /// When Weir first saw the request pending: the ledger's record
    /// (`ApprovalLedger.Entry.firstSeenAt`), else the pending list's. Now,
    /// for a request neither knows, which only makes it the newest; it can
    /// never make a later prompt look as if it overtook the request.
    func firstSeenAt(for approval: ApprovalPresentation) -> Date {
        ledger.entry(for: approval)?.firstSeenAt ?? firstSeenAtByID[approval.id] ?? Date()
    }

    private nonisolated static func observe(
        store: ApprovalPresentationStore,
        generation: UUID
    ) async {
        while !Task.isCancelled {
            do {
                try await observeConnection(store: store, generation: generation)
            } catch {
                log.error("Approval subscription disconnected: \(String(describing: error), privacy: .private)")
                await store.connectionDidDisconnect(generation: generation)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private nonisolated static func observeConnection(
        store: ApprovalPresentationStore,
        generation: UUID
    ) async throws {
        let (client, epoch) = try ApprovalControllerConnection.openSession(timeoutSeconds: 70)
        var response = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.snapshot(epoch: epoch)
        ))
        while !Task.isCancelled {
            let receivedAt = SuspendingClock.now
            // Read just before the lookups, so a request that left the list
            // since the last pass is looked up rather than missed.
            let trackedIDs = await store.ledger.trackedIDs
            let projection = try ApprovalControllerConnection.projection(
                from: response,
                epoch: epoch,
                receivedAt: receivedAt,
                trackedIDs: trackedIDs
            ) { runID, requestID in
                try ApprovalControllerConnection.fetch(client, epoch: epoch, runID: runID, requestID: requestID)
            }
            await store.replacePending(projection, epoch: epoch, generation: generation)
            response = try AgentIntegrationApprovalWire.object(from: client.exchange(
                AgentIntegrationApprovalWire.subscribe(
                    epoch: epoch,
                    afterSequence: projection.sequence,
                    maximumWaitMilliseconds: 60000
                )
            ))
        }
    }

    /// The unevictable record count at which the broker counts as nearly
    /// full: three quarters of the service's `MAXIMUM_RECORDS` (128), early
    /// enough to say so before requests start falling back to the provider's
    /// prompt.
    static let nearCapacityRecordCount = 96

    private func replacePending(_ projection: ApprovalControllerConnection.Projection, epoch: UUID, generation: UUID) {
        guard observerGeneration == generation else { return }
        apply(projection, epoch: epoch, now: SuspendingClock.now)
    }

    /// Applies one broker projection: the ledger first, so it has the new
    /// requests before anything reads the pending list. `seenAt` is the
    /// wall clock a new request is first seen at, by the ledger and the
    /// pending list alike.
    func apply(_ projection: ApprovalControllerConnection.Projection, epoch: UUID, now: SuspendingClock.Instant, seenAt: Date = Date()) {
        applyLedger(projection, epoch: epoch, now: now, seenAt: seenAt)
        updatePending(projection.requests, epoch: epoch, seenAt: seenAt)
        // Times the requests against their deadlines as well.
        applyServiceDeadlines(projection.deadlines, epoch: epoch)
        onRequestsChanged()
        let isNearCapacity = projection.unevictableCount >= Self.nearCapacityRecordCount
        if isNearCapacity, !self.isNearCapacity {
            Self.log.notice("Approval broker holds \(projection.unevictableCount, privacy: .public) unevictable records")
        }
        self.isNearCapacity = isNearCapacity
    }

    /// Carries a projection into the ledger: the pending requests, how each
    /// tracked request that left the list ended, and which ones the broker
    /// no longer has.
    private func applyLedger(
        _ projection: ApprovalControllerConnection.Projection,
        epoch: UUID,
        now: SuspendingClock.Instant,
        seenAt: Date
    ) {
        ledger.observe(pending: projection.requests, epoch: epoch, seenAt: seenAt)
        for (id, terminal) in projection.terminals {
            ledger.settle(id: id, by: terminal, now: now)
        }
        for id in projection.missingIDs {
            ledger.markMissing(id: id, now: now)
        }
    }

    /// Takes a reading of the time left, keeping only requests that are
    /// still pending in the epoch we observe: a reading from another epoch
    /// would attach a deadline to requests the service no longer knows.
    ///
    /// The subscription and the wake refresh read on separate connections
    /// and land here in either order, so an older reading can arrive last.
    /// Within one epoch a request's deadline never changes, so per request
    /// the reading taken later on our clock wins, and a request missing from
    /// this reading keeps the one it had.
    func applyServiceDeadlines(_ deadlines: [String: ServiceDeadline], epoch: UUID) {
        guard observedEpoch == epoch else { return }
        let pendingIDs = Set(pending.map(\.id))
        let fresh = deadlines.filter { pendingIDs.contains($0.key) }
        serviceDeadlines.merge(fresh) { current, incoming in
            incoming.receivedAt >= current.receivedAt ? incoming : current
        }
        scheduleDeadlineCheck()
    }

    /// Reads the service clock again, for after the Mac wakes. Both clocks
    /// stop during sleep, so the time left should not move; reading it again
    /// is what keeps that an observation rather than an assumption.
    ///
    /// Returns the read in flight, nil when none was started, so a test can
    /// wait for what became of it rather than for a stretch of time.
    @discardableResult
    func refreshServiceClock() -> Task<Void, Never>? {
        // Nothing to refresh before the first projection or after `stop()`,
        // and a reading with no epoch to match would be dropped anyway.
        guard observedEpoch != nil else { return nil }
        let generation = observerGeneration
        let reader = serviceClockReader
        return Task { [weak self] in
            do {
                let reading = try await reader()
                guard let self, observerGeneration == generation else { return }
                applyServiceDeadlines(reading.deadlines, epoch: reading.epoch)
            } catch {
                Self.log.error("Approval clock refresh failed: \(String(describing: error), privacy: .private)")
            }
        }
    }

    /// Calls `refreshServiceClock()` whenever `center` posts `name`. The app
    /// layer passes the workspace's wake notification, which Core cannot name.
    func refreshServiceClock(onEvery name: Notification.Name, in center: NotificationCenter) {
        if let wakeObservation {
            wakeObservation.center.removeObserver(wakeObservation.token)
        }
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.refreshServiceClock()
            }
        }
        wakeObservation = (center, token)
    }

    private func connectionDidDisconnect(generation: UUID) {
        guard observerGeneration == generation else { return }
        connectionDidDrop()
    }

    /// The subscription dropped while the service stays ready. Split from
    /// `connectionDidDisconnect` so a test can drop a connection it never
    /// opened, without the generation check.
    func connectionDidDrop() {
        pending = []
        serviceDeadlines = [:]
        // The ledger stays: a reconnect to the same epoch reports how the
        // tracked requests ended, and a new epoch carries over the ones
        // still waiting at the agent's prompt (`ApprovalLedger.outliveEpoch`).
        // Clearing it here would lose requests still waiting at the TUI over
        // a transient XPC failure.
        resolvingIDs = []
        // A card follows the ledger, which outlives a dropped connection,
        // and keeps its place: the anchors of the requests the ledger holds
        // stay, and `hasRow` already drops the arrow.
        onRequestsChanged()
        deadlineTask?.cancel()
        deadlineTask = nil
        // `observedActiveTurnIDs` stays with the ledger it describes.
        settledIDs = []
        failedReleaseIDs = []
    }

    /// Carries a projection's pending requests into the pending list, once
    /// the ledger has them (`apply`): every pending request is one the
    /// ledger holds, or one whose episode ended (`ApprovalLedger.hasEnded`).
    private func updatePending(_ approvals: [ApprovalPresentation], epoch: UUID, seenAt: Date) {
        if observedEpoch != epoch {
            observedEpoch = epoch
            firstSeenAtByID = [:]
        }
        for approval in approvals where firstSeenAtByID[approval.id] == nil {
            firstSeenAtByID[approval.id] = seenAt
        }
        pending = approvals
        serviceDeadlines = serviceDeadlines.filter { entry in approvals.contains { $0.id == entry.key } }
        resolvingIDs.formIntersection(approvals.map(\.id))
        // Kept past the pending list while the ledger holds the request, for
        // the end of its episode (`endFinishedEpisodes`).
        observedActiveTurnIDs = observedActiveTurnIDs.filter { id in
            approvals.contains { $0.id == id } || ledger.entry(id: id) != nil
        }
        settledIDs = settledIDs.filter { id in approvals.contains { $0.id == id } }
        failedReleaseIDs = failedReleaseIDs.filter { id in approvals.contains { $0.id == id } }
        answerDrafts = answerDrafts.filter { isKnown($0.key) }
        // A request that leaves the pending list keeps its card while the
        // ledger says it is still open, with the TUI, or timed out; the rows
        // of a request no longer known lose their frames.
        onRequestsChanged()
    }
}
