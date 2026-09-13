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
    let toolName: String
    let summary: String?
    let inputDescription: String
    let deadlineMilliseconds: UInt64

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
    private var observerTask: Task<Void, Never>?

    func start() {
        guard observerTask == nil else { return }
        observerTask = Task { await Self.observe(store: self) }
    }

    func resolve(_ approval: ApprovalPresentation, decision: String) {
        guard decision == "allow_once" || decision == "deny",
              resolvingIDs.insert(approval.id).inserted
        else { return }
        Task {
            do {
                try await Self.sendDecision(approval, decision: decision)
            } catch {
                Self.log.error("Approval decision failed: \(String(describing: error), privacy: .public)")
            }
            resolvingIDs.remove(approval.id)
        }
    }

    func paneLocation(for approval: ApprovalPresentation, in session: WindowSession) -> (UUID, UUID)? {
        guard let sessionID = approval.sessionID else { return nil }
        for tab in session.tabs {
            let sessions = switch approval.provider {
            case .claude: tab.claudeSessions
            case .codex: tab.codexSessions
            }
            if let paneID = sessions.first(where: { $0.value.sessionId == sessionID })?.key {
                return (tab.id, paneID)
            }
        }
        return nil
    }

    private nonisolated static func observe(store: ApprovalPresentationStore) async {
        while !Task.isCancelled {
            do {
                try await observeConnection(store: store)
            } catch {
                log.error("Approval subscription disconnected: \(String(describing: error), privacy: .public)")
                await store.replacePending([])
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private nonisolated static func observeConnection(store: ApprovalPresentationStore) async throws {
        let client = try AgentIntegrationXPCClient(role: .controller, timeoutSeconds: 70)
        _ = try client.openSession()
        let hello = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.hello(clientVersion: "limpid-controller-v1")
        ))
        let epoch = try AgentIntegrationApprovalWire.epoch(from: hello)
        let initial = try AgentIntegrationApprovalWire.object(from: client.exchange(
            AgentIntegrationApprovalWire.snapshot(epoch: epoch)
        ))
        var currentProjection = try projection(from: initial, epoch: epoch, client: client)
        var sequence = currentProjection.sequence
        await store.replacePending(currentProjection.requests)
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
            await store.replacePending(currentProjection.requests)
        }
    }

    private nonisolated static func sendDecision(
        _ approval: ApprovalPresentation,
        decision: String
    ) async throws {
        let client = try AgentIntegrationXPCClient(role: .controller)
        _ = try client.openSession()
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
                decision: decision
            )
        ))
        guard response["type"] as? String == "approval.result" else {
            throw AgentIntegrationError.invalidResponse
        }
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
                toolName: toolName,
                summary: request["summary"] as? String,
                inputDescription: inputDescription,
                deadlineMilliseconds: deadline
            ))
        }
        return (sequence, requests.sorted { $0.id < $1.id })
    }

    private func replacePending(_ approvals: [ApprovalPresentation]) {
        pending = approvals
        resolvingIDs.formIntersection(approvals.map(\.id))
    }
}
