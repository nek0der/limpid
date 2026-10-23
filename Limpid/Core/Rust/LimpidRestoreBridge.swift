// LimpidRestoreBridge.swift
// Limpid — Swift entry point for restoring a worktree to the start of a turn through the Rust bridge.

import Foundation
import LimpidRustBridge

/// One provider's state directory, where Rust reads the run records again
/// under the worktree lock to see whether an agent of the worktree is at
/// work.
struct RestoreStateDirectory: Encodable, Equatable, Sendable {
    let provider: AgentKind
    let directory: URL

    private enum CodingKeys: String, CodingKey {
        case provider, directory
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider.rawValue, forKey: .provider)
        try container.encode(directory.path, forKey: .directory)
    }
}

/// What a restore or an undo planned, wrote, and found, as Rust journals it
/// (`limpid_agent_model::RestoreJournal`). Only what the app shows or acts
/// on is read.
struct RestoreJournal: Decodable, Equatable, Sendable {
    /// What an operation took back (`limpid_agent_model::RestoreOperation`).
    enum Operation: String, Decodable, Sendable {
        case restore
        /// Hunks discarded in the review.
        case discard
        /// One a newer bridge added.
        case unknown

        init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let opID: String
    /// A restore when the journal does not say: one from before discards.
    let operation: Operation
    /// The worktree written.
    let root: String
    /// The turn whose start the worktree went back to; for an undo, the
    /// turn of the restore it undid.
    let turnID: TurnID
    /// The turn's number in its conversation ("T7"), kept by the journal:
    /// the record names the turn after the turn's own record may be gone.
    let turnNumber: Int?
    let paneID: String
    /// The restore this one undid, for an undo.
    let undoes: String?
    let plannedPaths: [RestorePathChange]
    let stage: RestoreStage
    /// When the journal was last written: by the operation's own call, or
    /// by a later one that settled it after a crash or marked it undone.
    let at: String
    /// When the operation ran, which no later call rewrites: what tells a
    /// turn that began after it, though recovery wrote the journal later.
    /// A journal from earlier builds has none, and its `at` stands in.
    let ranAt: String

    private enum CodingKeys: String, CodingKey {
        case opID = "opId"
        case operation
        case root
        case turnID = "turnId"
        case turnNumber
        case paneID = "paneId"
        case undoes, plannedPaths, stage, at, ranAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        opID = try container.decode(String.self, forKey: .opID)
        operation = try container.decodeIfPresent(Operation.self, forKey: .operation) ?? .restore
        root = try container.decode(String.self, forKey: .root)
        turnID = try container.decode(TurnID.self, forKey: .turnID)
        turnNumber = try container.decodeIfPresent(Int.self, forKey: .turnNumber)
        paneID = try container.decode(String.self, forKey: .paneID)
        undoes = try container.decodeIfPresent(String.self, forKey: .undoes)
        plannedPaths = try container.decode([RestorePathChange].self, forKey: .plannedPaths)
        stage = try container.decode(RestoreStage.self, forKey: .stage)
        at = try container.decode(String.self, forKey: .at)
        ranAt = try container.decodeIfPresent(String.self, forKey: .ranAt) ?? at
    }

    /// Whether this is an operation whose work is in the working tree now
    /// and that an undo may take back: applied, or partly applied, and not
    /// undone. A restore's record shows until it is; a discard's hunk
    /// offers "Undo Discard".
    var isUndoable: Bool {
        guard undoes == nil else { return false }
        switch stage {
        case .applied, .partiallyApplied: return true
        default: return false
        }
    }
}

/// What a restore does to one path. A rename is a delete and an add.
struct RestorePathChange: Decodable, Equatable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case add, modify, delete, unknown

        init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let path: String
    let kind: Kind
}

/// A save another writer made at a path while an operation wrote it,
/// which the operation moved aside rather than delete: written through a
/// file the operation had already taken out of the path.
struct RestoreKeptAside: Equatable, Sendable {
    let path: String
    /// Where the save is now, relative to the worktree.
    let location: String
}

/// Why an operation ended short of applied, or applied with saves kept
/// aside (`limpid_agent_model::StageReason`), by the code its journal
/// writes. The app's one table of these codes.
enum RestoreStageReason: String, Decodable, Equatable, Sendable {
    /// A hook asked the operation to stop: an agent's prompt goes first.
    case agentStarted
    /// A path could not be written.
    case writeFailed
    /// Another writer changed a planned path while the operation ran.
    case externalChangeDetected
    /// A crash cut the operation short, and recovery settled it.
    case interrupted
    /// Every planned path holds what the operation wrote, and saves another
    /// writer made meanwhile were moved aside.
    case keptAside
    /// A code a newer bridge added.
    case unknown

    init(from decoder: any Decoder) throws {
        self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }
}

/// Where a restore stands (`limpid_agent_model::RestoreStage`).
enum RestoreStage: Decodable, Equatable, Sendable {
    case planned
    case writing
    case verifying
    case applied
    case undone(by: String)
    case aborted(reason: RestoreStageReason)
    /// `kept` are the planned paths another writer changed, kept as it
    /// left them; `failed` the paths that could not be written;
    /// `keptAside` the saves moved out of the way.
    case partiallyApplied(reason: RestoreStageReason, kept: [String], failed: [String], keptAside: [RestoreKeptAside] = [])
    /// A stage a newer bridge added.
    case unknown

    private enum CodingKeys: String, CodingKey {
        case kind, by, reason, kept, failed
    }

    /// A path not written (`limpid_agent_model::FailedPath`). Only whether
    /// it is a save kept aside, and where, is read; the reason's other codes
    /// and its `detail` are the journal reader's.
    private struct Failed: Decodable {
        let path: String
        let reason: String?
        let keptAt: String?

        /// How a journal from earlier builds named a save kept aside, with
        /// the place after it; still read so, never written.
        private static let legacyKeptAsidePrefix = "keptAside:"

        var keptAside: RestoreKeptAside? {
            if reason == RestoreStageReason.keptAside.rawValue, let keptAt {
                return RestoreKeptAside(path: path, location: keptAt)
            }
            guard keptAt == nil, let reason, reason.hasPrefix(Self.legacyKeptAsidePrefix) else { return nil }
            return RestoreKeptAside(path: path, location: String(reason.dropFirst(Self.legacyKeptAsidePrefix.count)))
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "planned": self = .planned
        case "writing": self = .writing
        case "verifying": self = .verifying
        case "applied": self = .applied
        case "undone": self = try .undone(by: container.decode(String.self, forKey: .by))
        case "aborted": self = try .aborted(reason: container.decode(RestoreStageReason.self, forKey: .reason))
        case "partiallyApplied":
            let failed = try container.decodeIfPresent([Failed].self, forKey: .failed) ?? []
            self = try .partiallyApplied(
                reason: container.decode(RestoreStageReason.self, forKey: .reason),
                kept: container.decodeIfPresent([String].self, forKey: .kept) ?? [],
                failed: failed.filter { $0.keptAside == nil }.map(\.path),
                keptAside: failed.compactMap(\.keptAside)
            )
        default: self = .unknown
        }
    }

    /// Whether a crash stopped the restore partway, as recovery found at
    /// launch.
    var isInterrupted: Bool {
        if case .partiallyApplied(.interrupted, _, _, _) = self {
            true
        } else {
            false
        }
    }

    /// Whether every planned path holds what the operation wrote: applied,
    /// or so with saves moved aside, which `keptAside` names.
    var isWhole: Bool {
        switch self {
        case .applied, .partiallyApplied(.keptAside, _, _, _): true
        default: false
        }
    }

    /// The saves the operation moved out of the way.
    var keptAside: [RestoreKeptAside] {
        if case let .partiallyApplied(_, _, _, keptAside) = self {
            keptAside
        } else {
            []
        }
    }

    /// Whether the operation had not finished when its journal was read:
    /// left unsettled when a hook held the lock.
    var isUnfinished: Bool {
        switch self {
        case .planned, .writing, .verifying: true
        default: false
        }
    }
}

/// What reading a worktree's journals found (`limpid_restore_recover_v1`).
struct RestoreRecovery: Decodable, Equatable, Sendable {
    /// Every journal of the worktree that could be read, oldest first.
    let journals: [RestoreJournal]
    /// The operations this reading settled.
    let settled: [String]
    /// Whether `journals` leaves out some that are there but could not be
    /// read: the ones it has were settled and dropped all the same, and
    /// what was known of the others stands. A `var` only so the memberwise
    /// initializer gives it a default; the bridge always sends it.
    var isIncomplete = false
}

/// Why a restore or an undo wrote nothing (`limpid_agent_hook::restore::Refusal`).
enum RestoreRefusal: Decodable, Equatable, Sendable {
    case notARepository
    case turnNotFound
    case turnNotCaptured
    case otherWorktree
    case agentActive(AgentKind?)
    /// A hook held the worktree lock throughout: a turn is beginning.
    case agentRecording
    /// A prompt was given before anything was written.
    case agentStarted
    case lockUnavailable
    /// The worktree is a sparse checkout, which a restore would fill in.
    case sparseCheckout
    case mergeInProgress
    case headMoved
    case branchChanged
    /// The restore would write over files no snapshot holds (ignored, past
    /// the size limit, or a file where a directory goes).
    case pathsInTheWay([String])
    /// Where the files are cannot swap two names in one step (FAT, exFAT, a
    /// network volume, or another volume inside the worktree), so a save
    /// made meanwhile could be lost.
    case unsupportedVolume
    /// It renames files to names their volume takes for the same file
    /// (only in case); the paths are the new names.
    case renamedInPlace([String])
    /// The undo of a discard would write files git now converts on
    /// checkout, which would not get their bytes back.
    case converted([String])
    /// The journal, or the file listing the refs that pin its trees, could
    /// not be written; `cause` says what failed, for the log.
    case journalUnwritable(cause: String)
    /// The journal of the restore to undo is there but could not be read,
    /// which a later try may; `cause` says what failed, for the log.
    case journalUnreadable(cause: String)
    case restoreNotFound
    case notUndoable
    case changedSinceRestore(paths: [String])
    case git(step: String)
    /// A reason a newer bridge added.
    case unknown

    /// Whether trying again cannot go otherwise, whatever the person or an
    /// agent does in the worktree: the operation is gone, done, or of a
    /// kind this place never takes. The others pass once an agent stops,
    /// a merge ends, a file is put back, or a setting (a sparse checkout,
    /// an attribute) is undone.
    var isLasting: Bool {
        switch self {
        case .notARepository, .turnNotFound, .turnNotCaptured, .otherWorktree, .restoreNotFound, .notUndoable,
             .unsupportedVolume, .renamedInPlace, .unknown:
            true
        case .agentActive, .agentRecording, .agentStarted, .lockUnavailable, .mergeInProgress, .headMoved,
             .branchChanged, .pathsInTheWay, .journalUnwritable, .journalUnreadable, .changedSinceRestore, .git,
             .sparseCheckout, .converted:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, provider, paths, step, cause
    }

    /// The reasons that carry nothing but their kind.
    private static let plain: [String: RestoreRefusal] = [
        "notARepository": .notARepository,
        "turnNotFound": .turnNotFound,
        "turnNotCaptured": .turnNotCaptured,
        "otherWorktree": .otherWorktree,
        "agentRecording": .agentRecording,
        "agentStarted": .agentStarted,
        "lockUnavailable": .lockUnavailable,
        "sparseCheckout": .sparseCheckout,
        "mergeInProgress": .mergeInProgress,
        "headMoved": .headMoved,
        "branchChanged": .branchChanged,
        "restoreNotFound": .restoreNotFound,
        "notUndoable": .notUndoable,
        "unsupportedVolume": .unsupportedVolume
    ]

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let paths = { try container.decodeIfPresent([String].self, forKey: .paths) ?? [] }
        switch kind {
        case "agentActive":
            self = try .agentActive(container.decodeIfPresent(String.self, forKey: .provider).flatMap(AgentKind.init(rawValue:)))
        case "pathsInTheWay": self = try .pathsInTheWay(paths())
        case "renamedInPlace": self = try .renamedInPlace(paths())
        case "converted": self = try .converted(paths())
        case "changedSinceRestore": self = try .changedSinceRestore(paths: paths())
        case "git": self = try .git(step: container.decodeIfPresent(String.self, forKey: .step) ?? "")
        case "journalUnwritable":
            self = try .journalUnwritable(cause: container.decodeIfPresent(String.self, forKey: .cause) ?? "")
        case "journalUnreadable":
            self = try .journalUnreadable(cause: container.decodeIfPresent(String.self, forKey: .cause) ?? "")
        default: self = Self.plain[kind] ?? .unknown
        }
    }
}

/// What became of a restore or an undo.
enum RestoreOutcome: Decodable, Equatable, Sendable {
    /// Nothing was written.
    case refused(RestoreRefusal)
    /// The journal's stage says how it ended.
    case finished(RestoreJournal)

    private enum CodingKeys: String, CodingKey {
        case outcome, refusal, journal
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .outcome) == "finished" {
            self = try .finished(container.decode(RestoreJournal.self, forKey: .journal))
        } else {
            self = try .refused(container.decode(RestoreRefusal.self, forKey: .refusal))
        }
    }
}

/// One hunk a discard was asked for, and what became of it.
struct DiscardHunkResult: Decodable, Equatable, Sendable {
    enum Result: String, Decodable, Sendable {
        case discarded
        /// Its lines are not in the file as the review showed them.
        case notFound
        /// Its file could not be written, or changed while the discard ran.
        case notWritten
        /// Git converts its file on checkout, so it could not be written
        /// back byte for byte.
        case converted
        /// A link, a submodule, or another kind of file is there now.
        case unsupported
        case unknown

        init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let path: String
    let header: String
    let result: Result
}

/// What became of a discard (`limpid_discard_hunks_v1`).
enum DiscardOutcome: Decodable, Equatable, Sendable {
    /// Nothing was written.
    case refused(RestoreRefusal)
    /// Each hunk's result, and the journal when anything was written.
    case finished(RestoreJournal?, [DiscardHunkResult])

    private enum CodingKeys: String, CodingKey {
        case outcome, refusal, journal, hunks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decode(String.self, forKey: .outcome) == "finished" {
            self = try .finished(
                container.decodeIfPresent(RestoreJournal.self, forKey: .journal),
                container.decode([DiscardHunkResult].self, forKey: .hunks)
            )
        } else {
            self = try .refused(container.decode(RestoreRefusal.self, forKey: .refusal))
        }
    }
}

/// The hunks of one file to discard, by their `@@` lines.
struct DiscardFile: Encodable, Equatable, Sendable {
    let path: String
    let hunks: [String]
}

/// A restore call the bridge refused (`limpid_turn_result`).
enum LimpidRestoreBridgeError: Error, Equatable {
    /// What the call reads could not be read (`LIMPID_TURN_UNREADABLE`):
    /// not "nothing there", so what was known of it stands.
    case unreadable
    /// Any other status the C ABI returned.
    case rust(Int32)

    init(status: Int32) {
        self = status == Int32(LIMPID_TURN_UNREADABLE.rawValue) ? .unreadable : .rust(status)
    }
}

/// Calls the restore work that lives in Rust, beside the lock the hooks
/// take. Every call runs git and may wait for the worktree lock, so it is
/// made off the main actor (`RestoreCoordinator`).
enum LimpidRestoreBridge {
    static func restore(
        root: String,
        turnID: TurnID,
        paneID: String,
        stateDirectories: [RestoreStateDirectory]
    ) throws -> RestoreOutcome {
        let request = try JSONEncoder().encode(
            RestoreTurnRequest(root: root, turnID: turnID.rawValue, paneID: paneID, stateDirectories: stateDirectories)
        )
        return try JSONDecoder().decode(RestoreOutcome.self, from: call(limpid_restore_turn_v1, request))
    }

    static func undo(root: String, opID: String, stateDirectories: [RestoreStateDirectory]) throws -> RestoreOutcome {
        let request = try JSONEncoder().encode(RestoreUndoRequest(root: root, opID: opID, stateDirectories: stateDirectories))
        return try JSONDecoder().decode(RestoreOutcome.self, from: call(limpid_restore_undo_v1, request))
    }

    /// Discards hunks of `range`: the review diffed the range's first
    /// turn's start against its last turn's end, and each hunk is named by
    /// its `@@` line.
    static func discard(
        range: ReviewTurnRange,
        lastTurnNumber: Int?,
        paneID: String,
        files: [DiscardFile],
        stateDirectories: [RestoreStateDirectory]
    ) throws -> DiscardOutcome {
        let request = try JSONEncoder().encode(DiscardRequest(
            root: range.root,
            fromTree: range.beginTree,
            toTree: range.endTree,
            turnID: range.endTurnID.rawValue,
            turnNumber: lastTurnNumber,
            paneID: paneID,
            files: files,
            stateDirectories: stateDirectories
        ))
        return try JSONDecoder().decode(DiscardOutcome.self, from: call(limpid_discard_hunks_v1, request))
    }

    /// Settles the restores of the worktree at `root` a crash cut short,
    /// and returns every journal it has, and which it settled. Journals it
    /// could not read are left out, and the recovery says it is incomplete
    /// (`RestoreRecovery.isIncomplete`). Throws
    /// `LimpidRestoreBridgeError.unreadable` when git could not say where
    /// they are, rather than say there are none.
    static func recover(root: String) throws -> RestoreRecovery {
        try JSONDecoder().decode(RestoreRecovery.self, from: call(limpid_restore_recover_v1, Data(root.utf8)))
    }

    private typealias Entry = (
        UnsafePointer<UInt8>?,
        Int,
        UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
        UnsafeMutablePointer<Int>?
    ) -> Int32

    private static func call(_ entry: Entry, _ input: Data) throws -> Data {
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = input.withUnsafeBytes { buffer in
            entry(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, &out, &outCount)
        }
        guard let out else { throw LimpidRestoreBridgeError(status: status) }
        // The bytes are ours whatever the status turned out to be.
        defer { limpid_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(LIMPID_TURN_OK.rawValue) else { throw LimpidRestoreBridgeError(status: status) }
        return Data(bytes: out, count: outCount)
    }
}

// MARK: - Requests

/// The bridge's wire spells the IDs `turnId`, `paneId`, and `opId`; our
/// Swift names keep the `ID` spelling and map onto them.
private struct RestoreTurnRequest: Encodable {
    let root: String
    let turnID: String
    let paneID: String
    let stateDirectories: [RestoreStateDirectory]

    private enum CodingKeys: String, CodingKey {
        case root, stateDirectories
        case turnID = "turnId"
        case paneID = "paneId"
    }
}

private struct RestoreUndoRequest: Encodable {
    let root: String
    let opID: String
    let stateDirectories: [RestoreStateDirectory]

    private enum CodingKeys: String, CodingKey {
        case root, stateDirectories
        case opID = "opId"
    }
}

private struct DiscardRequest: Encodable {
    let root: String
    let fromTree: String
    let toTree: String
    let turnID: String
    let turnNumber: Int?
    let paneID: String
    let files: [DiscardFile]
    let stateDirectories: [RestoreStateDirectory]

    private enum CodingKeys: String, CodingKey {
        case root, fromTree, toTree, turnNumber, files, stateDirectories
        case turnID = "turnId"
        case paneID = "paneId"
    }
}
