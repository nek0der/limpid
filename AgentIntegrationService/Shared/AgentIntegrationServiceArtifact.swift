// AgentIntegrationServiceArtifact.swift
// Limpid — content identity for the bundled approval service and launch agent.

import CryptoKit
import Foundation

struct AgentIntegrationServiceArtifact: Codable, Equatable, Sendable {
    static let formatVersion = 1

    let formatVersion: Int
    let serviceExecutableSHA256: String
    let launchAgentPropertyListSHA256: String

    init(
        formatVersion: Int = Self.formatVersion,
        serviceExecutableSHA256: String,
        launchAgentPropertyListSHA256: String
    ) {
        self.formatVersion = formatVersion
        self.serviceExecutableSHA256 = serviceExecutableSHA256
        self.launchAgentPropertyListSHA256 = launchAgentPropertyListSHA256
    }

    static func bundled(
        in appBundleURL: URL,
        plistName: String = AgentIntegrationConfiguration.plistName
    ) throws -> Self {
        let serviceURL = appBundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("AgentIntegrationService")
        let propertyListURL = appBundleURL
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(plistName)
        return try Self(
            serviceExecutableSHA256: digest(of: serviceURL),
            launchAgentPropertyListSHA256: digest(of: propertyListURL)
        )
    }

    static func matchesBundle(
        _ artifact: Self?,
        containing executableURL: URL
    ) throws -> Bool {
        let appBundleURL = executableURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try artifact == bundled(in: appBundleURL)
    }

    private static func digest(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
