// AttentionKeys.swift
// Weir — the identities that attention items, turns, and conversations are keyed by.

import Foundation

/// One turn of an agent conversation, as the hook helper numbered it.
///
/// A string rather than a `UUID` because the helper writes it and the app
/// only compares it: a turn written by a newer helper with another format
/// must still be readable. The display number (T7) is not an identity; it
/// lives on the turn record.
package struct TurnID: Hashable, Codable, Sendable {
    package let rawValue: String

    package init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One agent conversation: the provider's session ID, or the run ID when the
/// provider did not report one.
///
/// `isFallback` is part of the identity so a run ID can never be mistaken
/// for a session ID that happens to have the same text. The coding keys use
/// the camelCase spelling the Rust side writes into its records.
package struct ConversationKey: Hashable, Codable, Sendable {
    package let provider: AgentKind
    package let conversationID: String
    package let isFallback: Bool

    package init(
        provider: AgentKind,
        conversationID: String,
        isFallback: Bool
    ) {
        self.provider = provider
        self.conversationID = conversationID
        self.isFallback = isFallback
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case conversationID = "conversationId"
        case isFallback
    }
}

/// One approval or question request, by the same three IDs the broker uses.
///
/// The epoch is part of the key because a restarted service numbers runs
/// and requests again; without it, a decision for a request from before the
/// restart could land on a new one.
package struct ApprovalKey: Hashable, Codable, Sendable {
    package let epoch: UUID
    package let runID: UUID
    package let requestID: UUID

    package init(
        epoch: UUID,
        runID: UUID,
        requestID: UUID
    ) {
        self.epoch = epoch
        self.runID = runID
        self.requestID = requestID
    }
}

/// One state episode of an agent or a session row: where it happened, and
/// which episode it is. Keys a stop, and a wait at the agent's own prompt
/// that Weir holds no request for.
///
/// The episode token makes a second stop of the same runtime a new item
/// rather than the old one coming back, so an item the person already dealt
/// with does not return when the agent fails again.
package struct EpisodeKey: Hashable, Codable, Sendable {
    package enum Origin: Hashable, Codable, Sendable {
        /// A running agent, by its runtime ID.
        case runtime(String)
        /// A session row whose agent never started, or whose worktree is
        /// gone, by the worktree's standardized path without a trailing
        /// slash. A path rather than a `URL`: `URL(fileURLWithPath:)` adds
        /// the slash only while the directory exists, so the key would
        /// change once the worktree disappeared. Make it with
        /// `sessionRow(worktreeRoot:)`, the one place that standardizes.
        case sessionRow(worktreePath: String)

        package static func sessionRow(worktreeRoot: URL) -> Origin {
            var path = worktreeRoot.standardizedFileURL.path
            while path.count > 1, path.hasSuffix("/") {
                path.removeLast()
            }
            return .sessionRow(worktreePath: path)
        }
    }

    package let origin: Origin
    package let episodeToken: String
}
