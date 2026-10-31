// ApprovalControllerConnection.swift
// Weir — the app's exchanges with the approval service, apart from what it shows.

import Foundation
import WeirDomain

/// What the controller asks the approval service and how it reads the
/// answers. Kept out of `ApprovalPresentationStore`, which owns what the app
/// shows, so the wire can be read and tested without a card, a pane, or a
/// main actor.
enum ApprovalControllerConnection {
    /// One broker projection, read in full.
    struct Projection: Sendable {
        let sequence: UInt64
        /// The pending requests, with their details.
        let requests: [ApprovalPresentation]
        /// How each tracked request that left the pending list ended.
        let terminals: [String: BrokerTerminal]
        /// Tracked requests the broker no longer has a record of.
        let missingIDs: Set<String>
        /// The records that could not be evicted to make room for a new
        /// request: pending ones and results their requester has not read.
        /// A new request is refused only when these fill the broker.
        let unevictableCount: Int
        let deadlines: [String: ServiceDeadline]
    }

    /// One reading of the service clock: the epoch it belongs to, and the
    /// time left on each pending request.
    struct ServiceClockReading: Sendable {
        let epoch: UUID
        let deadlines: [String: ServiceDeadline]
    }

    /// Opens a controller session on the bundled service and returns it with
    /// the service's epoch. The one way every controller exchange starts.
    static func openSession(timeoutSeconds: Int? = nil) throws -> (client: AgentIntegrationXPCClient, epoch: UUID) {
        let client = if let timeoutSeconds {
            try AgentIntegrationXPCClient(role: .controller, timeoutSeconds: timeoutSeconds)
        } else {
            try AgentIntegrationXPCClient(role: .controller)
        }
        try validateCurrentService(client.openSession())
        let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.hello(clientVersion: "weir-controller-v1")
        ))
        return try (client, AgentIntegrationApprovalWire.epoch(from: hello))
    }

    /// Reads a snapshot or subscribe result. Pending requests are read in
    /// full; a request in `trackedIDs` that is no longer pending is looked up
    /// to learn how it ended, because the index says only that it ended.
    /// `fetch` performs one `approval.get` and returns its response.
    static func projection(
        from response: [String: Any],
        epoch: UUID,
        receivedAt: SuspendingClock.Instant,
        trackedIDs: Set<String>,
        fetch: (_ runID: UUID, _ requestID: UUID) throws -> [String: Any]
    ) throws -> Projection {
        guard response["type"] as? String == "approval.snapshot.result",
              let body = response["body"] as? [String: Any],
              let sequence = (body["sequence"] as? NSNumber)?.uint64Value,
              let indices = body["requests"] as? [[String: Any]]
        else { throw AgentIntegrationError.invalidResponse }
        var requests: [ApprovalPresentation] = []
        var terminals: [String: BrokerTerminal] = [:]
        var indexedIDs: Set<String> = []
        for index in indices {
            guard let runID = (index["run_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let requestID = (index["request_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let status = index["status"] as? String
            else { throw AgentIntegrationError.invalidResponse }
            let id = ApprovalPresentation.id(epoch: epoch, runID: runID, requestID: requestID)
            indexedIDs.insert(id)
            if status == "pending" {
                try requests.append(presentation(from: fetch(runID, requestID), epoch: epoch, runID: runID, requestID: requestID))
            } else if trackedIDs.contains(id) {
                let detail = try fetch(runID, requestID)
                if let terminal = brokerTerminal(fromDetail: detail) {
                    terminals[id] = terminal
                } else if isNotFound(detail) {
                    // Evicted between the index and the lookup.
                    indexedIDs.remove(id)
                }
            }
        }
        return Projection(
            sequence: sequence,
            requests: requests.sorted { $0.id < $1.id },
            terminals: terminals,
            missingIDs: trackedIDs.subtracting(indexedIDs),
            // Every record counts when the service does not report the
            // split, which only a service other than the bundled one would do.
            unevictableCount: (body["unevictable_records"] as? NSNumber)?.intValue ?? indices.count,
            deadlines: serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: receivedAt)
        )
    }

    /// How a request ended, from an `approval.get` response, or `nil` while
    /// it is still pending. A `not_found` error is not an ending the broker
    /// reported; the caller treats it as a missing record.
    static func brokerTerminal(fromDetail detail: [String: Any]) -> BrokerTerminal? {
        guard detail["type"] as? String == "approval.result",
              let body = detail["body"] as? [String: Any],
              let state = body["state"] as? [String: Any]
        else { return nil }
        switch state["status"] as? String {
        case "resolved":
            return (state["result"] as? [String: Any])
                .flatMap(ApprovalResolution.init(wire:))
                .map(BrokerTerminal.resolved)
        case "canceled": return .canceled
        case "expired": return .expired
        default: return nil
        }
    }

    /// Whether an `approval.get` answered that the broker has no such record.
    static func isNotFound(_ response: [String: Any]) -> Bool {
        response["type"] as? String == "error"
            && (response["body"] as? [String: Any])?["code"] as? String == "not_found"
    }

    /// The time left on each pending request in a snapshot result body, read
    /// against the service clock (`now_ms`) the body carries. Empty when the
    /// body carries no clock. `receivedAt` is when the response arrived on
    /// our clock; the service clock and ours both stop while the Mac sleeps,
    /// so the difference stays true across a sleep.
    static func serviceDeadlines(
        fromSnapshotBody body: [String: Any],
        epoch: UUID,
        receivedAt: SuspendingClock.Instant
    ) -> [String: ServiceDeadline] {
        guard let serviceNow = (body["now_ms"] as? NSNumber)?.uint64Value,
              let indices = body["requests"] as? [[String: Any]]
        else { return [:] }
        var deadlines: [String: ServiceDeadline] = [:]
        for index in indices where index["status"] as? String == "pending" {
            guard let runID = (index["run_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let requestID = (index["request_id"] as? String).flatMap(UUID.init(uuidString:)),
                  let deadline = (index["deadline_ms"] as? NSNumber)?.uint64Value
            else { continue }
            deadlines[ApprovalPresentation.id(epoch: epoch, runID: runID, requestID: requestID)] = ServiceDeadline(
                deadlineMs: deadline,
                serviceNowMs: serviceNow,
                receivedAt: receivedAt
            )
        }
        return deadlines
    }

    /// Why the broker refused a decision. Distinct from a failed send: the
    /// request was settled elsewhere, so sending again cannot help.
    enum DecisionRefusal: Error, Equatable {
        /// Another answer reached the broker first (the TUI, the menu bar, a
        /// second card), or the request expired or was withdrawn.
        case alreadySettled(BrokerTerminal)
        /// The broker no longer has the request.
        case recordMissing
    }

    /// Sends a decision. Throws `DecisionRefusal` when the broker refused it
    /// because the request was already settled, after asking how: the
    /// `already_terminal` error carries only a code and a message. Also
    /// throws `.recordMissing` when the service restarted since, because the
    /// request belonged to a broker that no longer exists.
    static func sendDecision(_ approval: ApprovalPresentation, _ resolution: ApprovalResolution) async throws {
        let (client, currentEpoch) = try openSession()
        // A restarted service has a new broker that never held this request,
        // so retrying cannot reach it.
        guard currentEpoch == approval.epoch else { throw DecisionRefusal.recordMissing }
        let response = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.resolve(
                epoch: approval.epoch,
                runID: approval.runID,
                requestID: approval.requestID,
                decision: resolution.wireDecision,
                answers: resolution.answers
            )
        ))
        if response["type"] as? String == "approval.result" {
            return
        }
        throw try refusal(of: response) {
            try fetch(client, epoch: approval.epoch, runID: approval.runID, requestID: approval.requestID)
        }
    }

    /// The refusal a failed `approval.resolve` stands for, asking the broker
    /// with `fetch` how the request ended when it says it already did. Any
    /// other answer is a plain failure the person may retry.
    static func refusal(
        of response: [String: Any],
        fetch: () throws -> [String: Any]
    ) throws -> DecisionRefusal {
        if isNotFound(response) {
            return .recordMissing
        }
        guard response["type"] as? String == "error",
              (response["body"] as? [String: Any])?["code"] as? String == "already_terminal"
        else { throw AgentIntegrationError.invalidResponse }
        let detail = try fetch()
        if let terminal = brokerTerminal(fromDetail: detail) {
            return .alreadySettled(terminal)
        }
        if isNotFound(detail) {
            return .recordMissing
        }
        throw AgentIntegrationError.invalidResponse
    }

    static func readServiceClock() async throws -> ServiceClockReading {
        let (client, epoch) = try openSession()
        let response = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.snapshot(epoch: epoch)
        ))
        let receivedAt = SuspendingClock.now
        guard response["type"] as? String == "approval.snapshot.result",
              let body = response["body"] as? [String: Any]
        else { throw AgentIntegrationError.invalidResponse }
        return ServiceClockReading(
            epoch: epoch,
            deadlines: serviceDeadlines(fromSnapshotBody: body, epoch: epoch, receivedAt: receivedAt)
        )
    }

    /// One `approval.get` on an open session.
    static func fetch(
        _ client: AgentIntegrationXPCClient,
        epoch: UUID,
        runID: UUID,
        requestID: UUID
    ) throws -> [String: Any] {
        try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.get(epoch: epoch, runID: runID, requestID: requestID)
        ))
    }

    private static func validateCurrentService(_ bootstrap: AgentIntegrationSessionBootstrap) throws {
        guard bootstrap.role == .controller,
              try bootstrap.serviceArtifact == (AgentIntegrationServiceArtifact.bundled(
                  in: Bundle.main.bundleURL
              ))
        else { throw AgentIntegrationError.invalidResponse }
    }

    /// The request an `approval.result` describes. Internal so a test can
    /// read a broker's own result through it.
    static func presentation(
        from detail: [String: Any],
        epoch: UUID,
        runID: UUID,
        requestID: UUID
    ) throws -> ApprovalPresentation {
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
        return ApprovalPresentation(
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
            questions: ApprovalQuestion.decode(request["questions"]),
            command: command(toolName: toolName, input: input),
            hasInputCommand: hasCommand(input: input),
            agentRunID: (request["agent_run_id"] as? String).flatMap(UUID.init(uuidString:))
        )
    }

    /// Whether a request's input holds a string `command`, for any tool:
    /// the providers then take its summary from it rather than from its
    /// `description` (rust/weir-provider-*/src/approval.rs).
    static func hasCommand(input: Any) -> Bool {
        (input as? [String: Any])?["command"] is String
    }

    /// The shell command a request runs: Bash's `command` when it is a
    /// string, and nothing for any other tool, whose summary may be a
    /// description rather than what runs. Claude names its shell tool Bash,
    /// as Codex's hooks do for PreToolUse; should Codex name it otherwise
    /// in a permission request (`shell`, with its command as a list), the
    /// request has no command and the menu bar does not allow it.
    static func command(toolName: String, input: Any) -> String? {
        guard toolName == "Bash" else { return nil }
        return (input as? [String: Any])?["command"] as? String
    }
}
