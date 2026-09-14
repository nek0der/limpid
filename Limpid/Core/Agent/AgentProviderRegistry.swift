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

/// What one provider needs the platform to set up for its hooks to reach
/// Limpid. Declared by the provider crate so adding one is a crate and its
/// fixtures, not a list on this side that could disagree about a name.
struct AgentInstallRecipe: Decodable {
    var environment: [Variable] = []

    struct Variable: Decodable {
        var name: String
        var value: Placeholder
    }

    /// What the platform substitutes. A value this build does not know is
    /// skipped rather than exported empty, because an empty directory path
    /// would send the provider's records somewhere nobody reads.
    enum Placeholder: String, Decodable {
        case stateDirectory = "state_directory"
        case sessionDirectory = "session_directory"
        case cwdEventsDirectory = "cwd_events_directory"
        case bundleID = "bundle_id"
        case hookArguments = "hook_arguments"
        case unknown

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Placeholder(rawValue: raw) ?? .unknown
        }
    }
}

extension AgentProviderRegistry {
    /// Read once, like the descriptors: the recipes are compiled in.
    static let recipes: [String: AgentInstallRecipe] = {
        do {
            return try JSONDecoder().decode(
                [String: AgentInstallRecipe].self,
                from: LimpidProjectionBridge.installRecipes()
            )
        } catch {
            log.error("install recipes unavailable: \(String(describing: error), privacy: .public)")
            return [:]
        }
    }()

    /// The environment one provider's recipe asks for, with each placeholder
    /// resolved against the directories this build actually uses.
    static func environment(
        for provider: String,
        state: URL,
        sessions: URL,
        cwdEvents: URL?
    ) -> [String: String] {
        var environment: [String: String] = [:]
        for variable in recipes[provider]?.environment ?? [] {
            switch variable.value {
            case .stateDirectory: environment[variable.name] = state.path
            case .sessionDirectory: environment[variable.name] = sessions.path
            case .cwdEventsDirectory:
                if let cwdEvents {
                    environment[variable.name] = cwdEvents.path
                }
            case .bundleID: environment[variable.name] = LimpidPaths.bundleID
            // The hook's own arguments are assembled where the hook path is
            // known, which is not here.
            case .hookArguments, .unknown: continue
            }
        }
        return environment
    }
}
