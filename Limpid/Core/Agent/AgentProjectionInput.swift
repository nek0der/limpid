// AgentProjectionInput.swift
// Limpid — what one projection pass is told, and what it answers with.

import Foundation

/// Everything the rules read that this process had to look up: the files in
/// the watched directories, which panes exist, which processes are alive,
/// where the user is looking.
///
/// Typed rather than assembled as a dictionary because every field on the
/// other side has a default: a mistyped key would not fail, it would quietly
/// mean "nothing here", and a pane would simply stop showing a badge.
struct AgentProjectionInput: Encodable {
    var providers: [String: AgentProviderDescriptor] = [:]
    var records: [AgentProjectionFile] = []
    var sessionRecords: [AgentProjectionFile] = []
    var cwdEvents: [AgentProjectionFile] = []
    var worktreeEvents: [AgentProjectionWorktreeFile] = []
    var resumeIntents: [AgentProjectionIntent] = []
    var marks = AgentProjectionMarks()
    var presence = AgentProjectionPresence()
    var tabs: [AgentProjectionTabPanes] = []
    var pidStatus: [String: String] = [:]
    var focus: AgentProjectionFocus?
    var acknowledged: [AgentCommandOutcome] = []
    var isBootstrap = false
}

/// One file found in a watched directory. `content` is absent when the file is
/// there but could not be read this pass, which is not the same as absent: the
/// rules keep the copy they already accepted rather than letting a badge blink
/// out and come back.
struct AgentProjectionFile: Encodable {
    var provider: String
    var name: String
    var content: String?
}

struct AgentProjectionWorktreeFile: Encodable {
    var provider: String
    var fileName: String
    var content: String
}

struct AgentProjectionIntent: Encodable {
    var runID: String
    var paneID: UUID
    var sessionID: String
    var ownerRunID: String?
    var pid: String
    var createdAt: String

    private enum CodingKeys: String, CodingKey {
        case runID, paneID, sessionID, ownerRunID, pid, createdAt
    }
}

/// Viewed and dismissed marks, as runtime identifier to the attention episode
/// they were taken against.
struct AgentProjectionMarks: Codable {
    var viewed: [String: String] = [:]
    var dismissed: [String: String] = [:]
}

/// Which panes each tmux endpoint reaches, and whether each is the active one
/// in its window.
///
/// Keys are identifier strings rather than `UUID` values: Swift encodes a
/// dictionary whose key is not a string as an array of alternating keys and
/// values, which is not the object shape the rules read.
struct AgentProjectionPresence: Encodable {
    var attachments: [String: [UUID]] = [:]
    var locations: [String: AgentProjectionPaneLocation] = [:]

    /// Keyed by socket and pane because that pair is what identifies one tmux
    /// endpoint, and the rules match a record's own fields against it.
    ///
    /// The rules build the same key from the record's own socket and pane, so
    /// this spelling is a contract neither side owns: change it here and a
    /// tmux-hosted run stops matching the pane it is showing in, with no error
    /// anywhere. `endpoint_key` is the other half.
    static func key(socketPath: String, pane: String) -> String {
        "\(socketPath)|\(pane)"
    }
}

struct AgentProjectionPaneLocation: Encodable {
    var isActive: Bool
}

struct AgentProjectionTabPanes: Encodable {
    var id: UUID
    var panes: [UUID]
}

struct AgentProjectionFocus: Encodable {
    var tab: UUID
    var pane: UUID
    /// Whether the user is actually looking at this window. A pane stays the
    /// focused one while the application is in the background, and the rules
    /// treat "seen" differently from "would be seen if you looked".
    var isActive: Bool
}

/// What a provider declares about itself, as the Rust registry reports it.
/// Only the parts the host needs are read; the rest round-trips untouched.
struct AgentProviderDescriptor: Codable {
    var id: String
    var displayName: String
    var capabilities: [String]
    var pidSweepIntervalMs: Int
    var stateDirectory: String
    var sessionDirectory: String
    var cwdEventsDirectory: String?
    var processNames: [String]
    var sessionEndDropReasons: [String]
}

/// What one pass answers with. The state it also returns travels as raw bytes
/// this process never reads, so it is lifted from the body separately.
struct AgentProjectionResponse: Decodable {
    var projection: AgentProjection
    var commands: [AgentProjectionCommand]
}

/// What to show. Pane and tab keys arrive as identifier strings for the same
/// reason the input uses them.
struct AgentProjection: Decodable {
    var runtimes: [AgentProjectedRuntime] = []
    var badges: [String: [String: AgentProjectedBadge]] = [:]
    var sessions: [String: [String: AgentProjectedSession]] = [:]
    var tabTitles: [String: String] = [:]
    var marksToKeep = AgentProjectionMarks()
    var resumeCandidates: [String: [String]] = [:]

    /// The pane-keyed maps, re-keyed by identifier rather than by the text of
    /// one. The two sides spell an identifier differently — lower case on the
    /// way out, upper case here — so comparing the strings would silently
    /// match nothing. Parsing them is what makes the spelling irrelevant.
    var badgesByPane: [UUID: [String: AgentProjectedBadge]] {
        Self.keyed(badges)
    }

    var sessionsByPane: [UUID: [String: AgentProjectedSession]] {
        Self.keyed(sessions)
    }

    var titlesByTab: [UUID: String] {
        Self.keyed(tabTitles)
    }

    var resumeCandidatesByPane: [UUID: [String]] {
        Self.keyed(resumeCandidates)
    }

    private static func keyed<Value>(_ source: [String: Value]) -> [UUID: Value] {
        var result: [UUID: Value] = [:]
        for (key, value) in source {
            if let identifier = UUID(uuidString: key) {
                result[identifier] = value
            }
        }
        return result
    }
}

struct AgentProjectedRuntime: Decodable {
    var id: String
    var provider: String
    var runID: String?
    var revision: Int?
    var badge: AgentProjectedBadge
    var panes: [UUID]
    var attachment: String
    var eventToken: String
    var episodeToken: String

    private enum CodingKeys: String, CodingKey {
        case id, provider
        case runID = "runId"
        case revision, badge, panes, attachment, eventToken, episodeToken
    }
}

struct AgentProjectedBadge: Decodable {
    var state: String
    var detail: String?
    var runStartedAt: String?
    var contextTokens: Int?
    var isTmuxHosted: Bool?
    var updatedAt: String
    var lastPrompt: String?
    var firstPrompt: String?
    var turnBaseTree: String?
    var turnRoot: String?
    var conversationID: String?
    var providerSessionTitle: String?
    var providerGeneratedTitle: String?
    var sessionStartedAt: String?

    private enum CodingKeys: String, CodingKey {
        case state, detail, runStartedAt, contextTokens, isTmuxHosted, updatedAt
        case lastPrompt, firstPrompt, turnBaseTree, turnRoot
        case conversationID = "conversationId"
        case providerSessionTitle, providerGeneratedTitle, sessionStartedAt
    }

    /// The badge as the interface holds it. An unreadable state shows as
    /// unknown rather than being dropped, matching what the rules decided
    /// about a state string this build does not know.
    var asAgentBadge: AgentBadge {
        AgentBadge(
            state: AgentState(rawValue: state) ?? .unknown,
            detail: detail,
            runStartedAt: AgentDateParsing.parseOptional(runStartedAt),
            contextTokens: contextTokens,
            isTmuxHosted: isTmuxHosted,
            updatedAt: AgentDateParsing.parseISO8601(updatedAt) ?? Date(),
            lastPrompt: lastPrompt,
            turnBaseTree: turnBaseTree,
            turnRoot: turnRoot,
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: providerSessionTitle,
            providerGeneratedTitle: providerGeneratedTitle,
            sessionStartedAt: AgentDateParsing.parseOptional(sessionStartedAt)
        )
    }
}

struct AgentProjectedSession: Decodable {
    var sessionID: String
    var cwd: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case cwd
    }
}
