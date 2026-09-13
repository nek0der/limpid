// AgentIntegrationServiceRegistrar.swift
// Limpid — reconciles the bundled approval service without needless restarts.

import AppKit
import Foundation
import OSLog
import ServiceManagement

enum AgentIntegrationRegistrationStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

enum AgentIntegrationRegistrationAction: Equatable, Sendable {
    case register
    case keep
    case replace
    case retry
    case awaitApproval
    case failNotFound
    case failUnknown
}

enum RunningServiceArtifactObservation: Equatable, Sendable {
    case notApplicable
    case response(AgentIntegrationServiceArtifact?)
    case unavailable
}

enum AgentIntegrationRegistrationDecision {
    static func action(
        status: AgentIntegrationRegistrationStatus,
        bundledArtifact: AgentIntegrationServiceArtifact,
        runningArtifact: RunningServiceArtifactObservation,
        marker: AgentIntegrationRegistrationMarker?
    ) -> AgentIntegrationRegistrationAction {
        switch status {
        case .notRegistered:
            return .register
        case .enabled:
            guard marker?.artifact == bundledArtifact,
                  marker?.phase == .ready || marker?.phase == .registered
            else { return .replace }
            guard case let .response(runningArtifact) = runningArtifact else {
                return .retry
            }
            return runningArtifact == bundledArtifact ? .keep : .replace
        case .requiresApproval:
            return .awaitApproval
        case .notFound:
            return .failNotFound
        case .unknown:
            return .failUnknown
        }
    }
}

struct AgentIntegrationRegistrationMarker: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    enum Phase: String, Codable, Sendable {
        case replacing
        case registered
        case ready
    }

    let schemaVersion: Int
    let phase: Phase
    let artifact: AgentIntegrationServiceArtifact
    let appVersion: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        phase: Phase,
        artifact: AgentIntegrationServiceArtifact,
        appVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.artifact = artifact
        self.appVersion = appVersion
    }
}

struct AgentIntegrationRegistrationMarkerStore: Sendable {
    let fileURL: URL

    func load() -> AgentIntegrationRegistrationMarker? {
        guard let data = try? Data(contentsOf: fileURL),
              let marker = try? JSONDecoder().decode(AgentIntegrationRegistrationMarker.self, from: data),
              marker.schemaVersion == AgentIntegrationRegistrationMarker.schemaVersion
        else { return nil }
        return marker
    }

    func write(_ marker: AgentIntegrationRegistrationMarker) throws {
        SecureFileWrite.ensureUserOnlyDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try SecureFileWrite.writeAtomic(encoder.encode(marker), to: fileURL)
    }
}

struct AgentIntegrationServiceIssue: Identifiable, Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        case requiresApproval
        case serviceNotFound
        case reconciliationFailed
    }

    let reason: Reason
    let diagnostic: String?

    var id: Reason {
        reason
    }

    var title: String {
        String(localized: "Native approvals are unavailable")
    }

    var detail: String {
        switch reason {
        case .requiresApproval:
            String(localized: "Enable Limpid in System Settings → General → Login Items & Extensions, then return to Limpid.")
        case .serviceNotFound:
            String(localized: "The bundled approval service could not be found. Reinstall Limpid and try again.")
        case .reconciliationFailed:
            String(localized: "Limpid could not start its approval service. Claude and Codex will use their native permission prompts.")
        }
    }
}

struct AgentIntegrationIssuePresentation: Equatable, Sendable {
    private(set) var issue: AgentIntegrationServiceIssue?
    private var dismissedReason: AgentIntegrationServiceIssue.Reason?

    mutating func present(_ issue: AgentIntegrationServiceIssue) {
        guard dismissedReason != issue.reason else { return }
        dismissedReason = nil
        self.issue = issue
    }

    mutating func dismiss() {
        guard let issue else { return }
        dismissedReason = issue.reason
        self.issue = nil
    }

    mutating func reset() {
        dismissedReason = nil
        issue = nil
    }
}

@MainActor
@Observable
final class AgentIntegrationServiceRegistrar {
    private static let log = Logger.limpid("agent-integration-service")
    private static let controlEnvironmentKey = "LIMPID_AGENT_SERVICE_CONTROL"

    private(set) var isReady = false
    private var issuePresentation = AgentIntegrationIssuePresentation()

    var issue: AgentIntegrationServiceIssue? {
        issuePresentation.issue
    }

    private let appBundleURL: URL
    private let markerStore: AgentIntegrationRegistrationMarkerStore
    private let appVersion: String
    private var reconcileTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var activeObserver: Any?
    private var readinessChanged: ((Bool) -> Void)?

    init(
        appBundleURL: URL = Bundle.main.bundleURL,
        applicationSupportDirectory: URL = LimpidPaths.applicationSupportDirectory(),
        appVersion: String? = nil
    ) {
        self.appBundleURL = appBundleURL
        markerStore = AgentIntegrationRegistrationMarkerStore(
            fileURL: applicationSupportDirectory
                .appendingPathComponent("agent-integration", isDirectory: true)
                .appendingPathComponent("service-registration.json")
        )
        self.appVersion = appVersion
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "unknown"
    }

    func start(readinessChanged: @escaping (Bool) -> Void) {
        guard !LimpidPaths.isRunningInTests else { return }
        self.readinessChanged = readinessChanged

        #if DEBUG
            if let command = ProcessInfo.processInfo.environment[Self.controlEnvironmentKey] {
                runDevelopmentCommand(command)
                return
            }
        #endif

        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    func retry() {
        issuePresentation.reset()
        retryTask?.cancel()
        retryTask = nil
        reconcile()
    }

    func dismissIssue() {
        issuePresentation.dismiss()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func reconcile(forceReplacement: Bool = false) {
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            defer { reconcileTask = nil }
            do {
                let artifact = try await bundledArtifactAndValidateCode()
                let service = SMAppService.agent(plistName: AgentIntegrationConfiguration.plistName)
                let status = registrationStatus(service.status)
                var observation = RunningServiceArtifactObservation.notApplicable
                var observationDiagnostic: String?
                if status == .enabled {
                    do {
                        observation = try await .response(Self.runningServiceArtifact())
                    } catch {
                        observation = .unavailable
                        observationDiagnostic = String(describing: error)
                    }
                }
                let action = forceReplacement && status == .enabled
                    ? AgentIntegrationRegistrationAction.replace
                    : AgentIntegrationRegistrationDecision.action(
                        status: status,
                        bundledArtifact: artifact,
                        runningArtifact: observation,
                        marker: markerStore.load()
                    )
                try await apply(
                    action,
                    service: service,
                    artifact: artifact,
                    diagnostic: observationDiagnostic
                )
            } catch {
                Self.log.error("Service reconciliation failed: \(String(describing: error), privacy: .public)")
                setUnavailable(.reconciliationFailed, diagnostic: String(describing: error))
            }
        }
    }

    private func apply(
        _ action: AgentIntegrationRegistrationAction,
        service: SMAppService,
        artifact: AgentIntegrationServiceArtifact,
        diagnostic: String?
    ) async throws {
        switch action {
        case .register:
            try writeMarker(phase: .replacing, artifact: artifact)
            try service.register()
            try writeMarker(phase: .registered, artifact: artifact)
            try await verifyRegisteredService(service, artifact: artifact)
        case .keep:
            try writeMarker(phase: .ready, artifact: artifact)
            setReady()
        case .replace:
            try writeMarker(phase: .replacing, artifact: artifact)
            let slowOperationNotice = Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                self?.setUnavailable(
                    .reconciliationFailed,
                    diagnostic: "Service removal is taking longer than expected."
                )
            }
            defer { slowOperationNotice.cancel() }
            try await Self.unregister(service)
            try service.register()
            try writeMarker(phase: .registered, artifact: artifact)
            try await verifyRegisteredService(service, artifact: artifact)
        case .retry:
            setUnavailable(.reconciliationFailed, diagnostic: diagnostic)
            scheduleRetry()
        case .awaitApproval:
            setUnavailable(.requiresApproval)
        case .failNotFound:
            setUnavailable(.serviceNotFound)
        case .failUnknown:
            throw AgentIntegrationError.invalidResponse
        }
    }

    private func verifyRegisteredService(
        _ service: SMAppService,
        artifact: AgentIntegrationServiceArtifact
    ) async throws {
        switch registrationStatus(service.status) {
        case .enabled:
            guard try await Self.runningServiceArtifact() == artifact else {
                throw AgentIntegrationError.invalidResponse
            }
            try writeMarker(phase: .ready, artifact: artifact)
            setReady()
        case .requiresApproval:
            setUnavailable(.requiresApproval)
        case .notFound:
            setUnavailable(.serviceNotFound)
        case .notRegistered, .unknown:
            throw AgentIntegrationError.invalidResponse
        }
    }

    private func bundledArtifactAndValidateCode() async throws -> AgentIntegrationServiceArtifact {
        let appBundleURL = appBundleURL
        return try await Task.detached {
            let executableDirectory = appBundleURL
                .appendingPathComponent("Contents/MacOS", isDirectory: true)
            try AgentIntegrationSigning.validateStaticCode(
                at: executableDirectory.appendingPathComponent("AgentIntegrationService"),
                identifier: AgentIntegrationConfiguration.serviceIdentifier
            )
            try AgentIntegrationSigning.validateStaticCode(
                at: executableDirectory.appendingPathComponent("AgentIntegrationHookHelper"),
                identifier: AgentIntegrationConfiguration.requesterIdentifiers[0]
            )
            return try AgentIntegrationServiceArtifact.bundled(in: appBundleURL)
        }.value
    }

    private nonisolated static func runningServiceArtifact() async throws -> AgentIntegrationServiceArtifact? {
        do {
            return try await queryRunningServiceArtifact()
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(200))
        }
        do {
            return try await queryRunningServiceArtifact()
        } catch {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(400))
        }
        return try await queryRunningServiceArtifact()
    }

    private nonisolated static func queryRunningServiceArtifact() async throws
        -> AgentIntegrationServiceArtifact?
    {
        try await Task.detached {
            let client = try AgentIntegrationXPCClient(role: .controller)
            let bootstrap = try client.openSession()
            guard bootstrap.role == .controller else {
                throw AgentIntegrationError.invalidResponse
            }
            return bootstrap.serviceArtifact
        }.value
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            retryTask = nil
            reconcile()
        }
    }

    private func writeMarker(
        phase: AgentIntegrationRegistrationMarker.Phase,
        artifact: AgentIntegrationServiceArtifact
    ) throws {
        try markerStore.write(AgentIntegrationRegistrationMarker(
            phase: phase,
            artifact: artifact,
            appVersion: appVersion
        ))
    }

    private func setReady() {
        retryTask?.cancel()
        retryTask = nil
        issuePresentation.reset()
        guard !isReady else { return }
        isReady = true
        readinessChanged?(true)
        Self.log.notice("Agent Integration Service is ready")
    }

    private func setUnavailable(
        _ reason: AgentIntegrationServiceIssue.Reason,
        diagnostic: String? = nil
    ) {
        issuePresentation.present(AgentIntegrationServiceIssue(
            reason: reason,
            diagnostic: diagnostic
        ))
        guard isReady else { return }
        isReady = false
        readinessChanged?(false)
    }

    private func registrationStatus(_ status: SMAppService.Status) -> AgentIntegrationRegistrationStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }

    private static func unregister(_ service: SMAppService) async throws {
        guard service.status != .notRegistered else { return }
        let _: Void = try await withCheckedThrowingContinuation { continuation in
            service.unregister { error in
                if let error {
                    continuation.resume(
                        throwing: AgentIntegrationError.requestFailed(error.localizedDescription)
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    #if DEBUG
        private func runDevelopmentCommand(_ command: String) {
            switch command {
            case "register":
                reconcile()
            case "refresh":
                reconcile(forceReplacement: true)
            case "unregister":
                reconcileTask = Task {
                    defer { reconcileTask = nil }
                    do {
                        try await Self.unregister(SMAppService.agent(
                            plistName: AgentIntegrationConfiguration.plistName
                        ))
                        setUnavailable(.reconciliationFailed, diagnostic: "unregistered by development control")
                    } catch {
                        setUnavailable(.reconciliationFailed, diagnostic: String(describing: error))
                    }
                }
            case "status":
                let service = SMAppService.agent(plistName: AgentIntegrationConfiguration.plistName)
                Self.log.notice("Agent Integration Service status: \(String(describing: service.status), privacy: .public)")
            default:
                setUnavailable(
                    .reconciliationFailed,
                    diagnostic: "LIMPID_AGENT_SERVICE_CONTROL must be register, refresh, unregister, or status."
                )
            }
        }
    #endif
}
