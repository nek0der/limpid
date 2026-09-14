// AgentProviderRegistry.swift
// Limpid — what the Rust side says the installed providers are.

import Foundation
import OSLog

private let log = Logger.limpid("agent.provider.registry")

/// The providers this build has, as they describe themselves.
///
/// Asked for rather than listed here. A second list on this side could
/// disagree with the one the rules branch on, and the ways it could disagree —
/// a directory name, a capability, a display name — are exactly the ways that
/// would be hard to notice.
enum AgentProviderRegistry {
    /// Read once: the set cannot change while the process runs, because it is
    /// compiled in.
    static let descriptors: [String: AgentProviderDescriptor] = {
        do {
            return try JSONDecoder().decode(
                [String: AgentProviderDescriptor].self,
                from: LimpidProjectionBridge.providers()
            )
        } catch {
            // An empty registry means no provider has any capability, so the
            // rules decide nothing rather than deciding wrongly.
            log.error("provider registry unavailable: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }()

    /// What to call a provider in front of the user. Falls back to the
    /// identifier, which is at least recognizable, rather than to nothing.
    static func displayName(for kind: AgentKind) -> String {
        descriptors[kind.rawValue]?.displayName ?? kind.rawValue
    }

    /// Where each provider keeps its records under `root`, as its descriptor
    /// declares. Claude keeps legacy directory names so existing records
    /// survive an upgrade, which is why this is read rather than derived.
    static func directories(under root: URL) -> [String: AgentDirectories] {
        descriptors.mapValues { descriptor in
            AgentDirectories(
                state: root.appendingPathComponent(descriptor.stateDirectory, isDirectory: true),
                sessions: root.appendingPathComponent(descriptor.sessionDirectory, isDirectory: true),
                cwdEvents: descriptor.cwdEventsDirectory.map {
                    root.appendingPathComponent($0, isDirectory: true)
                }
            )
        }
    }
}
