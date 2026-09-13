// AgentIntegrationConfiguration.swift
// Limpid — identifiers and signing policy for the macOS integration service.

import Foundation
import Security

enum AgentIntegrationConfiguration {
    static let maximumXPCRequestBytes = 1024 * 1024
    static let maximumXPCResponseBytes = 64 * 1024
    static let maximumRecords = 128

    #if DEBUG
        static let plistName = "dev.limpid.agent-integration-service.dev.plist"
        static let launchAgentLabel = "dev.limpid.agent-integration-service.dev"
        static let requesterMachService = "dev.limpid.agent-integration-service.dev.requester"
        static let controllerMachService = "dev.limpid.agent-integration-service.dev.controller"
        static let serviceIdentifier = "dev.limpid.AgentIntegrationService.dev"
        static let requesterIdentifiers = [
            "dev.limpid.AgentIntegrationHookHelper.dev",
            "dev.limpid.AgentIntegrationRequesterProbe.dev"
        ]
        static let controllerIdentifiers = [
            "dev.limpid.Limpid.dev",
            "dev.limpid.AgentIntegrationControllerProbe.dev"
        ]
    #else
        static let plistName = "dev.limpid.agent-integration-service.plist"
        static let launchAgentLabel = "dev.limpid.agent-integration-service"
        static let requesterMachService = "dev.limpid.agent-integration-service.requester"
        static let controllerMachService = "dev.limpid.agent-integration-service.controller"
        static let serviceIdentifier = "dev.limpid.AgentIntegrationService"
        static let requesterIdentifiers = ["dev.limpid.AgentIntegrationHookHelper"]
        static let controllerIdentifiers = ["dev.limpid.Limpid"]
    #endif
}

enum AgentIntegrationRole: String, Codable, Sendable {
    case requester
    case controller
}

struct AgentIntegrationSessionBootstrap: Codable, Sendable {
    let role: AgentIntegrationRole
    let runID: UUID?
    let serviceProcessID: Int32
}

enum AgentIntegrationSigning {
    static func requirement(peerIdentifiers: [String]) throws -> String {
        guard !peerIdentifiers.isEmpty else {
            throw AgentIntegrationError.invalidConfiguration("A peer identifier is required.")
        }
        guard let teamIdentifier = try currentTeamIdentifier() else {
            throw AgentIntegrationError.adHocSigningUnsupported
        }
        let identifiers = peerIdentifiers
            .map { "identifier \"\($0)\"" }
            .joined(separator: " or ")
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\" "
            + "and (\(identifiers))"
    }

    private static func currentTeamIdentifier() throws -> String? {
        let executableURL = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var currentCode: SecStaticCode?
        let staticCodeStatus = SecStaticCodeCreateWithPath(executableURL as CFURL, [], &currentCode)
        guard staticCodeStatus == errSecSuccess, let currentCode else {
            throw AgentIntegrationError.securityStatus(staticCodeStatus)
        }

        var information: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            currentCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard informationStatus == errSecSuccess,
              let values = information as? [CFString: Any]
        else {
            throw AgentIntegrationError.securityStatus(informationStatus)
        }
        return values[kSecCodeInfoTeamIdentifier] as? String
    }
}

enum AgentIntegrationError: Error, CustomStringConvertible {
    case adHocSigningUnsupported
    case invalidArguments(String)
    case invalidConfiguration(String)
    case invalidResponse
    case requestFailed(String)
    case rustFailure(Int32)
    case securityStatus(OSStatus)
    case timeout

    var description: String {
        switch self {
        case .adHocSigningUnsupported:
            "Agent Integration Service registration requires an Apple-issued signing identity with a Team ID."
        case let .invalidArguments(message), let .invalidConfiguration(message):
            message
        case .invalidResponse:
            "The Agent Integration Service returned an invalid response."
        case let .requestFailed(message):
            "The Agent Integration Service request failed: \(message)"
        case let .rustFailure(code):
            "The Rust approval host rejected the operation with status \(code)."
        case let .securityStatus(status):
            "Security framework returned OSStatus \(status)."
        case .timeout:
            "The Agent Integration Service did not reply before the deadline."
        }
    }
}
