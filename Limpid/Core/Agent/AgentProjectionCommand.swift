// AgentProjectionCommand.swift
// Limpid — the side effects the Rust rules ask this process to perform.

import Foundation

/// One side effect, the precondition to recheck under the file lock, and what
/// follows it.
///
/// Records stay opaque across the boundary, but commands cannot: the work they
/// name is filesystem work this process already owns, so it has to understand
/// them. The shapes mirror the Rust vocabulary exactly; anything this build
/// does not recognize decodes as `unknown` and is skipped rather than failing
/// the whole batch, so a newer rule set cannot stall an older host.
struct AgentProjectionCommand: Decodable {
    var op: AgentCommandOperation
    var target: AgentCommandTarget
    var expect: AgentCommandPrecondition
    var onMismatch: AgentCommandMismatchPolicy
    var then: [AgentProjectionCommand]

    enum CodingKeys: String, CodingKey {
        case op, target, expect, onMismatch, then
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        op = try container.decode(AgentCommandOperation.self, forKey: .op)
        target = try container.decode(AgentCommandTarget.self, forKey: .target)
        expect = try container.decode(AgentCommandPrecondition.self, forKey: .expect)
        onMismatch = try container.decode(AgentCommandMismatchPolicy.self, forKey: .onMismatch)
        then = try container.decodeIfPresent([AgentProjectionCommand].self, forKey: .then) ?? []
    }
}

/// What to do to the target.
enum AgentCommandOperation: Decodable {
    case retire
    case update(AgentRecordPatch)
    case delete
    case writeResumeIntent(AgentResumeIntentPayload)
    case pruneRetired(max: Int, lifetimeSeconds: Int)
    case cleanupPaneStore(keep: Set<UUID>, max: Int)
    case notify(AgentNotifyPayload)
    case markViewed(runtimeID: String, token: String)
    case cwdChanged(pane: UUID, newCwd: String, oldCwd: String?)
    case gitSyncRefetch(repoRoot: String)
    /// An operation this build does not know. Skipped, never guessed at.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case op, max, lifetimeSecs, keep, runtimeId, token, pane, newCwd, oldCwd, repoRoot
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .op) {
        case "retire": self = .retire
        case "delete": self = .delete
        case "update":
            self = try .update(AgentRecordPatch(from: decoder))
        case "writeResumeIntent":
            self = try .writeResumeIntent(AgentResumeIntentPayload(from: decoder))
        case "pruneRetired":
            self = try .pruneRetired(
                max: container.decode(Int.self, forKey: .max),
                lifetimeSeconds: container.decode(Int.self, forKey: .lifetimeSecs)
            )
        case "cleanupPaneStore":
            self = try .cleanupPaneStore(
                keep: container.decode(Set<UUID>.self, forKey: .keep),
                max: container.decode(Int.self, forKey: .max)
            )
        case "notify":
            self = try .notify(AgentNotifyPayload(from: decoder))
        case "markViewed":
            self = try .markViewed(
                runtimeID: container.decode(String.self, forKey: .runtimeId),
                token: container.decode(String.self, forKey: .token)
            )
        case "cwdChanged":
            self = try .cwdChanged(
                pane: container.decode(UUID.self, forKey: .pane),
                newCwd: container.decode(String.self, forKey: .newCwd),
                oldCwd: container.decodeIfPresent(String.self, forKey: .oldCwd)
            )
        case "gitSyncRefetch":
            self = try .gitSyncRefetch(repoRoot: container.decode(String.self, forKey: .repoRoot))
        default:
            self = .unknown
        }
    }
}

/// What the command addresses, which is what decides the file to lock.
/// Encodable too, because an outcome names the target it is about.
enum AgentCommandTarget: Codable, Equatable {
    case record(provider: String, storageID: String)
    case sessionHint(provider: String, pane: UUID)
    case resumeIntent(runID: String)
    case worktreeEvent(provider: String, fileName: String)
    case retiredRecords(provider: String)
    case paneStore(provider: String, store: AgentPaneStoreKind)
    /// Nothing on disk. Notifications, viewed marks, and refetches need no
    /// lock and are applied by the adapter rather than the executor.
    case host
    case unknown

    private enum CodingKeys: String, CodingKey {
        case target, provider, storageId, pane, runId, fileName, store
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = { try container.decode(String.self, forKey: .provider) }
        switch try container.decode(String.self, forKey: .target) {
        case "record":
            self = try .record(
                provider: provider(),
                storageID: container.decode(String.self, forKey: .storageId)
            )
        case "sessionHint":
            self = try .sessionHint(
                provider: provider(),
                pane: container.decode(UUID.self, forKey: .pane)
            )
        case "resumeIntent":
            self = try .resumeIntent(runID: container.decode(String.self, forKey: .runId))
        case "worktreeEvent":
            self = try .worktreeEvent(
                provider: provider(),
                fileName: container.decode(String.self, forKey: .fileName)
            )
        case "retiredRecords":
            self = try .retiredRecords(provider: provider())
        case "paneStore":
            self = try .paneStore(
                provider: provider(),
                store: container.decode(AgentPaneStoreKind.self, forKey: .store)
            )
        case "host":
            self = .host
        default:
            self = .unknown
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .record(provider, storageID):
            try container.encode("record", forKey: .target)
            try container.encode(provider, forKey: .provider)
            try container.encode(storageID, forKey: .storageId)
        case let .sessionHint(provider, pane):
            try container.encode("sessionHint", forKey: .target)
            try container.encode(provider, forKey: .provider)
            try container.encode(pane, forKey: .pane)
        case let .resumeIntent(runID):
            try container.encode("resumeIntent", forKey: .target)
            try container.encode(runID, forKey: .runId)
        case let .worktreeEvent(provider, fileName):
            try container.encode("worktreeEvent", forKey: .target)
            try container.encode(provider, forKey: .provider)
            try container.encode(fileName, forKey: .fileName)
        case let .retiredRecords(provider):
            try container.encode("retiredRecords", forKey: .target)
            try container.encode(provider, forKey: .provider)
        case let .paneStore(provider, store):
            try container.encode("paneStore", forKey: .target)
            try container.encode(provider, forKey: .provider)
            try container.encode(store, forKey: .store)
        case .host, .unknown:
            // An unrecognized target has no name to report it under, so it
            // reports as the one that needs no lock.
            try container.encode("host", forKey: .target)
        }
    }
}

enum AgentPaneStoreKind: String, Codable {
    case sessions
    case cwdEvents
}

/// What must still hold when the lock is taken. The projection reasoned
/// about a snapshot, and a hook may have written since.
enum AgentCommandPrecondition: Decodable {
    case none
    case exists
    case recordUnchanged(storageID: String, revision: Int?, pid: String?, updatedAt: String)
    case pidAndRevision(pid: String?, revision: Int?)
    case hintOwner(runID: String?)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case expect, storageId, revision, pid, updatedAt, runId
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .expect) {
        case "none": self = .none
        case "exists": self = .exists
        case "recordUnchanged":
            self = try .recordUnchanged(
                storageID: container.decode(String.self, forKey: .storageId),
                revision: container.decodeIfPresent(Int.self, forKey: .revision),
                pid: container.decodeIfPresent(String.self, forKey: .pid),
                updatedAt: container.decode(String.self, forKey: .updatedAt)
            )
        case "pidAndRevision":
            self = try .pidAndRevision(
                pid: container.decodeIfPresent(String.self, forKey: .pid),
                revision: container.decodeIfPresent(Int.self, forKey: .revision)
            )
        case "hintOwner":
            self = try .hintOwner(runID: container.decodeIfPresent(String.self, forKey: .runId))
        default:
            self = .unknown
        }
    }
}

/// Whether a failed precondition stops the chain. A busy lock always
/// stops it, whatever this says.
enum AgentCommandMismatchPolicy: String, Decodable {
    case `continue`
    case abort
}

/// Fields a record update changes. Anything absent is left alone.
///
/// The keys are decoded one at a time because a patch names only what it
/// touches, and synthesized decoding would require every key to be present.
struct AgentRecordPatch: Decodable {
    var state: AgentPatchField<String>
    var pid: AgentPatchField<String>
    var killedByLimpidAt: AgentPatchField<String>
    var resumeAttemptedAt: AgentPatchField<String>

    private enum CodingKeys: String, CodingKey {
        case state, pid, killedByLimpidAt, resumeAttemptedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let field = { (key: CodingKeys) in
            (try? container.decodeIfPresent(AgentPatchField<String>.self, forKey: key)) ?? nil
        }
        state = field(.state) ?? .keep
        pid = field(.pid) ?? .keep
        killedByLimpidAt = field(.killedByLimpidAt) ?? .keep
        resumeAttemptedAt = field(.resumeAttemptedAt) ?? .keep
    }

}

/// The intent written at terminate so the next launch can tell a run
/// Limpid killed from one that ended on its own.
struct AgentResumeIntentPayload: Decodable {
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

/// One announcement, with what the host must echo back so a stale delivery
/// cannot retire a newer pending entry.
struct AgentNotifyPayload: Decodable {
    var provider: String
    var kind: AgentNotificationKind
    var tab: UUID
    var pane: UUID
    var runtimeID: String
    var body: String?
    var presentsBanner: Bool
    var suppressWhenPaneFocused: Bool
    var episodeToken: String
    var eventToken: String
    var state: String

    private enum CodingKeys: String, CodingKey {
        case provider, kind, tab, pane
        case runtimeID = "runtimeId"
        case body, presentsBanner, suppressWhenPaneFocused, episodeToken, eventToken, state
    }
}

/// One field of a record patch. Clearing a field and leaving it alone are
/// different intents, so they are different cases rather than a nested
/// optional.
///
/// A word this build does not recognize reads as "leave it alone", which is
/// the only safe way to be wrong about an instruction to change stored state.
enum AgentPatchField<Value: Decodable>: Decodable {
    case keep
    case clear
    case set(Value)

    private enum CodingKeys: String, CodingKey {
        case set
    }

    init(from decoder: any Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(String.self) {
            self = word == "clear" ? .clear : .keep
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try .set(container.decode(Value.self, forKey: .set))
    }
}

/// Why an announcement is being raised. The wording is the host's to build,
/// because it is localized and names the provider from the registry.
enum AgentNotificationKind: String, Decodable {
    case finished
    case needsInput
    case failed
}

/// What became of a command, reported back so the next pass can act on it.
///
/// Only a delivered notification changes what the rules do today; the rest are
/// reported because the outcome of a precondition is the kind of thing the
/// next pass should be able to see, and adding it later would mean changing
/// the boundary rather than a rule.
enum AgentCommandOutcome: Encodable {
    case notified(runtimeID: String, eventToken: String, state: String)
    case applied(AgentCommandTarget)
    case mismatched(AgentCommandTarget)
    case busy(AgentCommandTarget)

    private enum CodingKeys: String, CodingKey {
        case outcome, runtimeId, eventToken, state, target
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .notified(runtimeID, eventToken, state):
            try container.encode("notified", forKey: .outcome)
            try container.encode(runtimeID, forKey: .runtimeId)
            try container.encode(eventToken, forKey: .eventToken)
            try container.encode(state, forKey: .state)
        case let .applied(target):
            try container.encode("applied", forKey: .outcome)
            try container.encode(target, forKey: .target)
        case let .mismatched(target):
            try container.encode("mismatched", forKey: .outcome)
            try container.encode(target, forKey: .target)
        case let .busy(target):
            try container.encode("busy", forKey: .outcome)
            try container.encode(target, forKey: .target)
        }
    }
}
