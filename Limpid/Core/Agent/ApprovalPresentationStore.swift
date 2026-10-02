// ApprovalPresentationStore.swift
// Limpid — transient controller projection for native agent approvals.

import Foundation
import OSLog

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

    var isQuestion: Bool {
        !questions.isEmpty
    }

    var hasQuestionTurnCompletion: Bool {
        provider == .claude && operationID?.hasPrefix(AgentQuestionTurnCompletion.operationIDPrefix) == true
    }

    var id: String {
        "\(epoch.uuidString):\(runID.uuidString):\(requestID.uuidString)"
    }
}

@MainActor
@Observable
final class ApprovalPresentationStore {
    private nonisolated static let log = Logger.limpid("agent-approval")
    private(set) var pending: [ApprovalPresentation] = []
    private(set) var resolvingIDs: Set<String> = []
    /// The request whose most recent user decision failed to reach the broker.
    /// Optional because nothing has failed yet, or a later resolve cleared it.
    private(set) var lastFailureID: String?
    /// The one request whose detail card is visible in this scene.
    /// This is presentation state only; the broker remains the authority.
    private(set) var presentedID: String?
    /// A row click requests one focus hand-off to the safe Deny action. This
    /// must not double as a pinned-presentation flag: once the hand-off
    /// finishes, visibility follows row/card hover and focus like the PR card.
    private(set) var cardFocusRequestID: String?
    private var firstSeenAtByID: [String: Date] = [:]
    private var observedEpoch: UUID?
    private var rowAnchors: [String: CGRect] = [:]
    private var previewingIDs: Set<String> = []
    private var cardIsHovering = false
    private var cardIsFocused = false
    /// Unsent answers by request. A question card closes on the same hover
    /// and focus rules as any other card, so its draft lives here rather than
    /// in the card's view state, and reopening the card restores it. Entries
    /// leave with their request.
    private var answerDrafts: [String: ApprovalAnswerDraft] = [:]
    private var previewDismissTask: Task<Void, Never>?
    private let previewDismissDelay: Duration
    private var observerTask: Task<Void, Never>?
    private var observerGeneration = UUID()
    /// We may miss `needsInput` between broker and runtime projections. Any
    /// active state establishes that a request preceded the next turn end.
    private var observedActiveTurnIDs: Set<String> = []
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
    /// default is the XPC path.
    private let decisionSender: @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void

    init(
        previewDismissDelay: Duration = PRHoverPresentation.dismissGrace,
        decisionSender: @escaping @Sendable (ApprovalPresentation, ApprovalResolution) async throws -> Void
            = ApprovalPresentationStore.sendDecision
    ) {
        self.previewDismissDelay = previewDismissDelay
        self.decisionSender = decisionSender
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
        resolvingIDs = []
        presentedID = nil
        cardFocusRequestID = nil
        firstSeenAtByID = [:]
        observedEpoch = nil
        rowAnchors = [:]
        previewingIDs = []
        cardIsHovering = false
        cardIsFocused = false
        answerDrafts = [:]
        previewDismissTask?.cancel()
        previewDismissTask = nil
        observedActiveTurnIDs = []
        settledIDs = []
        failedReleaseIDs = []
    }

    func resolve(_ approval: ApprovalPresentation, _ resolution: ApprovalResolution) {
        send(resolution, for: approval, isUserDecision: true)
    }

    /// A user's decision owns the card's failure line. A background release
    /// does not: nobody pressed anything, so its failure must neither show a
    /// "try again" on the card nor clear a failure another decision left.
    private func send(_ resolution: ApprovalResolution, for approval: ApprovalPresentation, isUserDecision: Bool) {
        guard resolvingIDs.insert(approval.id).inserted else { return }
        if isUserDecision, lastFailureID == approval.id {
            lastFailureID = nil
        }
        Task {
            do {
                try await decisionSender(approval, resolution)
                settledIDs.insert(approval.id)
            } catch {
                Self.log.error("Approval decision failed: \(String(describing: error), privacy: .public)")
                if isUserDecision {
                    lastFailureID = approval.id
                } else {
                    failedReleaseIDs.insert(approval.id)
                }
            }
            resolvingIDs.remove(approval.id)
        }
    }

    /// Releases requests the terminal already answered. The helper prints
    /// nothing for `delegate`; the provider ignores it because the tool has
    /// already run, and the card and Waiting row disappear with the record.
    ///
    /// We cannot correlate Claude's PermissionRequest with a tool-use ID, so
    /// we release only once the pane's turn ends. Other tools can restore
    /// `running` while a dialog is open; that alone proves no answer.
    /// Scoped question requesters read their own turn-end receipts instead;
    /// a pane's turn end may belong to another prompt or a background agent.
    func releaseStaleApprovals(in session: WindowSession) {
        for approval in pending {
            guard !approval.hasQuestionTurnCompletion,
                  let (tabID, paneID) = paneLocation(for: approval, in: session),
                  let badge = session.tab(tabID)?.agentBadges[approval.provider]?[paneID]
            else { continue }
            let state = badge.state
            if state == .needsInput || state == .running || state == .compacting {
                observedActiveTurnIDs.insert(approval.id)
            } else if Self.turnIsOver(state),
                      observedActiveTurnIDs.contains(approval.id),
                      !resolvingIDs.contains(approval.id),
                      !settledIDs.contains(approval.id),
                      !failedReleaseIDs.contains(approval.id)
            {
                send(.delegate, for: approval, isUserDecision: false)
            }
        }
    }

    private static func turnIsOver(_ state: AgentState) -> Bool {
        switch state {
        case .finished, .error, .idle: true
        case .unknown, .running, .compacting, .needsInput: false
        }
    }

    func present(_ approval: ApprovalPresentation, shouldFocusCard: Bool = true) {
        guard pending.contains(approval) else { return }
        previewDismissTask?.cancel()
        if presentedID == approval.id {
            if shouldFocusCard {
                cardFocusRequestID = approval.id
            }
            return
        }
        cardIsHovering = false
        cardIsFocused = false
        presentedID = approval.id
        cardFocusRequestID = shouldFocusCard ? approval.id : nil
    }

    func previewBegan(_ approval: ApprovalPresentation) {
        guard pending.contains(approval) else { return }
        previewingIDs.insert(approval.id)
        previewDismissTask?.cancel()
        guard presentedID != approval.id else { return }
        cardIsHovering = false
        cardIsFocused = false
        presentedID = approval.id
        cardFocusRequestID = nil
    }

    func dismissCard() {
        previewDismissTask?.cancel()
        previewDismissTask = nil
        presentedID = nil
        cardFocusRequestID = nil
        cardIsHovering = false
        cardIsFocused = false
    }

    func previewEnded(_ approval: ApprovalPresentation) {
        previewingIDs.remove(approval.id)
        guard let presentedID else { return }
        schedulePreviewDismiss(for: presentedID)
    }

    func cardHoverChanged(_ hovering: Bool) {
        cardIsHovering = hovering
        if hovering {
            previewDismissTask?.cancel()
        } else if let presentedID {
            schedulePreviewDismiss(for: presentedID)
        }
    }

    func cardFocusChanged(_ focused: Bool, for approval: ApprovalPresentation) {
        guard presentedID == approval.id else { return }
        cardIsFocused = focused
        if focused {
            cardFocusRequestID = nil
            previewDismissTask?.cancel()
        } else if cardFocusRequestID == nil {
            schedulePreviewDismiss(for: approval.id)
        }
    }

    func cardFocusRequestCompleted(for approval: ApprovalPresentation) {
        guard cardFocusRequestID == approval.id else { return }
        cardFocusRequestID = nil
        if !cardIsFocused {
            schedulePreviewDismiss(for: approval.id)
        }
    }

    func answerDraft(for approval: ApprovalPresentation) -> ApprovalAnswerDraft {
        answerDrafts[approval.id] ?? ApprovalAnswerDraft()
    }

    func updateAnswerDraft(_ draft: ApprovalAnswerDraft, for approval: ApprovalPresentation) {
        guard pending.contains(approval) else { return }
        answerDrafts[approval.id] = draft
    }

    var presentedApproval: ApprovalPresentation? {
        guard let presentedID else { return nil }
        return pending.first { $0.id == presentedID }
    }

    func approval(forPaneID paneID: UUID, in session: WindowSession) -> ApprovalPresentation? {
        pending.first { paneLocation(for: $0, in: session)?.1 == paneID }
    }

    func updateRowAnchor(_ rect: CGRect, for approval: ApprovalPresentation) {
        guard pending.contains(approval) else { return }
        rowAnchors[approval.id] = rect
    }

    func rowAnchor(for approval: ApprovalPresentation) -> CGRect? {
        rowAnchors[approval.id]
    }

    func firstSeenAt(for approval: ApprovalPresentation) -> Date {
        firstSeenAtByID[approval.id] ?? Date()
    }

    func paneLocation(for approval: ApprovalPresentation, in session: WindowSession) -> (UUID, UUID)? {
        guard let sessionID = approval.sessionID else { return nil }
        for tab in session.tabs {
            let sessions = switch approval.provider {
            case .claude: tab.agentSessions[.claude] ?? [:]
            case .codex: tab.agentSessions[.codex] ?? [:]
            }
            if let paneID = sessions.first(where: { $0.value.sessionId == sessionID })?.key {
                return (tab.id, paneID)
            }
        }
        return nil
    }

    private nonisolated static func observe(
        store: ApprovalPresentationStore,
        generation: UUID
    ) async {
        while !Task.isCancelled {
            do {
                try await observeConnection(store: store, generation: generation)
            } catch {
                log.error("Approval subscription disconnected: \(String(describing: error), privacy: .public)")
                await store.connectionDidDisconnect(generation: generation)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private nonisolated static func observeConnection(
        store: ApprovalPresentationStore,
        generation: UUID
    ) async throws {
        let client = try AgentIntegrationXPCClient(role: .controller, timeoutSeconds: 70)
        try validateCurrentService(client.openSession())
        let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.hello(clientVersion: "limpid-controller-v1")
        ))
        let epoch = try AgentIntegrationApprovalWire.epoch(from: hello)
        let initial = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.snapshot(epoch: epoch)
        ))
        var currentProjection = try projection(from: initial, epoch: epoch, client: client)
        var sequence = currentProjection.sequence
        await store.replacePending(currentProjection.requests, epoch: epoch, generation: generation)
        while !Task.isCancelled {
            let response = try AgentIntegrationApprovalWire.object(from: client.exchange(
                AgentIntegrationApprovalWire.subscribe(
                    epoch: epoch,
                    afterSequence: sequence,
                    maximumWaitMilliseconds: 60000
                )
            ))
            currentProjection = try projection(from: response, epoch: epoch, client: client)
            sequence = currentProjection.sequence
            await store.replacePending(currentProjection.requests, epoch: epoch, generation: generation)
        }
    }

    private nonisolated static func sendDecision(
        _ approval: ApprovalPresentation,
        _ resolution: ApprovalResolution
    ) async throws {
        let client = try AgentIntegrationXPCClient(role: .controller)
        try validateCurrentService(client.openSession())
        let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.hello(clientVersion: "limpid-controller-v1")
        ))
        let currentEpoch = try AgentIntegrationApprovalWire.epoch(from: hello)
        guard currentEpoch == approval.epoch else { throw AgentIntegrationError.invalidResponse }
        let response = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.resolve(
                epoch: approval.epoch,
                runID: approval.runID,
                requestID: approval.requestID,
                decision: resolution.wireDecision,
                answers: resolution.answers
            )
        ))
        guard response["type"] as? String == "approval.result" else {
            throw AgentIntegrationError.invalidResponse
        }
    }

    private nonisolated static func validateCurrentService(
        _ bootstrap: AgentIntegrationSessionBootstrap
    ) throws {
        guard bootstrap.role == .controller,
              try bootstrap.serviceArtifact == (AgentIntegrationServiceArtifact.bundled(
                  in: Bundle.main.bundleURL
              ))
        else { throw AgentIntegrationError.invalidResponse }
    }

    private nonisolated static func projection(
        from response: [String: Any],
        epoch: UUID,
        client: AgentIntegrationXPCClient
    ) throws -> (sequence: UInt64, requests: [ApprovalPresentation]) {
        guard response["type"] as? String == "approval.snapshot.result",
              let body = response["body"] as? [String: Any],
              let sequence = (body["sequence"] as? NSNumber)?.uint64Value,
              let indices = body["requests"] as? [[String: Any]]
        else { throw AgentIntegrationError.invalidResponse }
        var requests: [ApprovalPresentation] = []
        for index in indices where index["status"] as? String == "pending" {
            guard let runValue = index["run_id"] as? String,
                  let requestValue = index["request_id"] as? String,
                  let runID = UUID(uuidString: runValue),
                  let requestID = UUID(uuidString: requestValue)
            else { throw AgentIntegrationError.invalidResponse }
            let detail = try AgentIntegrationApprovalWire.object(from: client.exchange(
                AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: requestID)
            ))
            guard detail["type"] as? String == "approval.result",
                  let detailBody = detail["body"] as? [String: Any],
                  let request = detailBody["request"] as? [String: Any],
                  let providerValue = request["provider"] as? String,
                  let provider = AgentKind(rawValue: providerValue),
                  let toolName = request["tool_name"] as? String,
                  let input = request["input"],
                  let deadline = (detailBody["deadline_ms"] as? NSNumber)?.uint64Value
            else { throw AgentIntegrationError.invalidResponse }
            let inputData = try JSONSerialization.data(
                withJSONObject: input,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            guard let inputDescription = String(bytes: inputData, encoding: .utf8) else {
                throw AgentIntegrationError.invalidResponse
            }
            requests.append(ApprovalPresentation(
                epoch: epoch,
                runID: runID,
                requestID: requestID,
                provider: provider,
                sessionID: request["session_id"] as? String,
                operationID: request["operation_id"] as? String,
                toolName: toolName,
                summary: request["summary"] as? String,
                requestDescription: (input as? [String: Any])?["description"] as? String,
                inputDescription: inputDescription,
                deadlineMilliseconds: deadline,
                questions: ApprovalQuestion.decode(request["questions"])
            ))
        }
        return (sequence, requests.sorted { $0.id < $1.id })
    }

    private func replacePending(_ approvals: [ApprovalPresentation], epoch: UUID, generation: UUID) {
        guard observerGeneration == generation else { return }
        updatePending(approvals, epoch: epoch)
    }

    private func connectionDidDisconnect(generation: UUID) {
        guard observerGeneration == generation else { return }
        pending = []
        resolvingIDs = []
        dismissCard()
        rowAnchors = [:]
        observedActiveTurnIDs = []
        settledIDs = []
        failedReleaseIDs = []
    }

    /// Applies a broker projection. Kept separate from the XPC observer so the
    /// presentation policy can be tested without a live service connection.
    func updatePending(_ approvals: [ApprovalPresentation], epoch: UUID? = nil) {
        let epoch = epoch ?? approvals.first?.epoch
        if observedEpoch != epoch {
            observedEpoch = epoch
            firstSeenAtByID = [:]
        }
        let now = Date()
        for approval in approvals where firstSeenAtByID[approval.id] == nil {
            firstSeenAtByID[approval.id] = now
        }
        pending = approvals
        resolvingIDs.formIntersection(approvals.map(\.id))
        rowAnchors = rowAnchors.filter { entry in
            approvals.contains { $0.id == entry.key }
        }
        previewingIDs.formIntersection(approvals.map(\.id))
        observedActiveTurnIDs = observedActiveTurnIDs.filter { id in approvals.contains { $0.id == id } }
        settledIDs = settledIDs.filter { id in approvals.contains { $0.id == id } }
        failedReleaseIDs = failedReleaseIDs.filter { id in approvals.contains { $0.id == id } }
        answerDrafts = answerDrafts.filter { entry in approvals.contains { $0.id == entry.key } }
        if let presentedID, !approvals.contains(where: { $0.id == presentedID }) {
            // A disappearing row also owns any card it presented. Other
            // requests remain quiet until their own row is previewed.
            dismissCard()
        }
    }

    private func schedulePreviewDismiss(for approvalID: String) {
        guard presentedID == approvalID,
              cardFocusRequestID == nil,
              previewingIDs.isEmpty
        else { return }
        previewDismissTask?.cancel()
        previewDismissTask = Task { @MainActor in
            try? await Task.sleep(for: previewDismissDelay)
            guard !Task.isCancelled,
                  presentedID == approvalID,
                  cardFocusRequestID == nil,
                  previewingIDs.isEmpty,
                  !cardIsHovering,
                  !cardIsFocused
            else { return }
            dismissCard()
        }
    }
}
