// AgentIntegrationServiceRegistrar.swift
// Limpid — development lifecycle control for the bundled approval service.

import Foundation
import OSLog
import ServiceManagement

enum AgentIntegrationServiceRegistrar {
    private static let log = Logger.limpid("agent-integration-service")
    private static let controlEnvironmentKey = "LIMPID_AGENT_SERVICE_CONTROL"

    static func applyDevelopmentCommandIfPresent() {
        #if DEBUG
            guard !LimpidPaths.isRunningInTests else { return }
            let command = ProcessInfo.processInfo.environment[controlEnvironmentKey] ?? "register"
            do {
                let service = SMAppService.agent(plistName: AgentIntegrationConfiguration.plistName)
                switch command {
                case "register":
                    _ = try AgentIntegrationSigning.requirement(peerIdentifiers: [
                        AgentIntegrationConfiguration.serviceIdentifier
                    ])
                    if service.status != .enabled {
                        try service.register()
                    }
                case "refresh":
                    _ = try AgentIntegrationSigning.requirement(peerIdentifiers: [
                        AgentIntegrationConfiguration.serviceIdentifier
                    ])
                    try unregister(service)
                    try service.register()
                case "unregister":
                    try unregister(service)
                case "status":
                    break
                default:
                    throw AgentIntegrationError.invalidArguments(
                        "LIMPID_AGENT_SERVICE_CONTROL must be register, refresh, unregister, or status."
                    )
                }
                let currentStatus = statusName(service.status)
                log.notice("Agent Integration Service \(command, privacy: .public): \(currentStatus, privacy: .public)")
            } catch {
                log.error("Agent Integration Service command failed: \(String(describing: error), privacy: .public)")
            }
        #endif
    }

    #if DEBUG
        private static func unregister(_ service: SMAppService) throws {
            guard service.status != .notRegistered else { return }
            let result = AgentIntegrationUnregisterResult()
            let semaphore = DispatchSemaphore(value: 0)
            service.unregister { error in
                result.set(error)
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + .seconds(10)) == .success else {
                throw AgentIntegrationError.timeout
            }
            if let error = result.get() {
                throw error
            }
        }

        private static func statusName(_ status: SMAppService.Status) -> String {
            switch status {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notFound: "notFound"
            @unknown default: "unknown"
            }
        }
    #endif
}

#if DEBUG
    private final class AgentIntegrationUnregisterResult: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?

        func set(_ error: (any Error)?) {
            lock.withLock { self.error = error }
        }

        func get() -> (any Error)? {
            lock.withLock { error }
        }
    }
#endif
