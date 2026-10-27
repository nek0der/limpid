// LimpidTurnBridge.swift
// Limpid — Swift entry point for deleting turns and ending declined waits through the Rust bridge.

import Foundation
import LimpidRustBridge

/// A turn call that could not be completed, with the C ABI's own status
/// (`limpid_turn_result`).
enum LimpidTurnBridgeError: Error {
    case rust(Int32)
}

/// What became of one turn asked to be deleted.
struct TurnDeletion: Decodable, Equatable, Sendable {
    enum Outcome: String, Decodable, Sendable {
        /// The record and its refs are gone.
        case deleted
        /// The record is gone; a repository it named could not be reached,
        /// so its refs may remain.
        case deletedLeavingRefs
        /// An earlier call took it.
        case alreadyGone
        /// A record this build may not delete, left as it is.
        case unreadable
        /// Something refused; the record stays for the next sweep.
        case failed
        /// A word a newer bridge added. Read as nothing in particular,
        /// rather than failing the whole batch.
        case unknown

        init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let outcome: Outcome
    let turnID: String
    /// Which step failed (moving the record, deleting the refs), English,
    /// for the log only.
    let reason: String?
    /// The repositories that could not be reached, whose refs may remain;
    /// for the log, so they can be found by hand.
    let roots: [String]?

    private enum CodingKeys: String, CodingKey {
        case outcome
        case turnID = "turnId"
        case reason
        case roots
    }

    /// Whether the turn's record is gone, its refs with it or not.
    var isGone: Bool {
        switch outcome {
        case .deleted, .deletedLeavingRefs, .alreadyGone: true
        case .failed, .unreadable, .unknown: false
        }
    }
}

/// Calls the turn work that lives in Rust, beside the hook that writes what
/// it removes.
enum LimpidTurnBridge {
    /// Deletes each of `turnIDs` from the turns directory `directory`: its
    /// record and the refs that pin its snapshots, together. Runs git,
    /// so it is called off the main actor (`TurnGarbageCollector`).
    static func deleteTurns(_ turnIDs: [String], in directory: URL) throws -> [TurnDeletion] {
        let path = Data(directory.path.utf8)
        let ids = try JSONEncoder().encode(turnIDs)
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = path.withUnsafeBytes { pathBuffer in
            ids.withUnsafeBytes { idsBuffer in
                limpid_turn_gc_apply_v1(
                    pathBuffer.bindMemory(to: UInt8.self).baseAddress,
                    pathBuffer.count,
                    idsBuffer.bindMemory(to: UInt8.self).baseAddress,
                    idsBuffer.count,
                    &out,
                    &outCount
                )
            }
        }
        guard let out else { throw LimpidTurnBridgeError.rust(status) }
        // The bytes are ours whatever the status turned out to be.
        defer { limpid_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(LIMPID_TURN_OK.rawValue) else { throw LimpidTurnBridgeError.rust(status) }
        return try JSONDecoder().decode([TurnDeletion].self, from: Data(bytes: out, count: outCount))
    }

    /// Ends the wait `request` names, which the person declined at the
    /// agent's own prompt and no hook reported: the run record is written
    /// as an interrupt ends it, and its turn too where that commit
    /// succeeds, if under the record's lock
    /// the record is still that wait and its transcript still reads
    /// declined. Runs git for the turn's end snapshot, so it is called off
    /// the main actor (`DeclinedWaitCloser`).
    static func endDeclinedWait(_ request: DeclinedWaitRequest) throws -> DeclinedWaitEnd {
        let body = try JSONEncoder().encode(request)
        var out: UnsafeMutablePointer<UInt8>?
        var outCount = 0
        let status = body.withUnsafeBytes { buffer in
            limpid_declined_wait_end_v1(
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count,
                &out,
                &outCount
            )
        }
        guard let out else { throw LimpidTurnBridgeError.rust(status) }
        // The bytes are ours whatever the status turned out to be.
        defer { limpid_approval_bytes_free_v1(out, outCount) }
        guard status == Int32(LIMPID_TURN_OK.rawValue) else { throw LimpidTurnBridgeError.rust(status) }
        return try JSONDecoder().decode(DeclinedWaitAnswer.self, from: Data(bytes: out, count: outCount)).outcome
    }

    private struct DeclinedWaitAnswer: Decodable {
        let outcome: DeclinedWaitEnd
    }
}

/// This is a wait a projection pass read as declined, as the bridge's writer
/// takes it (`endDeclinedWait` and the command's record target).
struct DeclinedWaitRequest: Encodable, Hashable, Sendable {
    let provider: String
    /// This is the provider's state directory, where its run records are.
    let stateDirectory: URL
    let storageID: String
    let episodeToken: String
    /// It is `nil` when the record names no turn.
    let turnID: String?
    let transcriptPath: String
    /// The agent's own OSC 7501 report, not the transcript, showed the wait
    /// over, so the writer does not ask the transcript.
    let byProgramStatus: Bool

    private enum CodingKeys: String, CodingKey {
        case provider, stateDirectory, storageID = "storageId", episodeToken, turnID = "turnId", transcriptPath,
             byProgramStatus
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(provider, forKey: .provider)
        // We encode the path, not the URL's own encoding, which would be a file URL.
        try container.encode(stateDirectory.path, forKey: .stateDirectory)
        try container.encode(storageID, forKey: .storageID)
        try container.encode(episodeToken, forKey: .episodeToken)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(transcriptPath, forKey: .transcriptPath)
        try container.encode(byProgramStatus, forKey: .byProgramStatus)
    }
}

/// This says what became of one request to end a declined wait.
enum DeclinedWaitEnd: String, Decodable, Sendable {
    /// The run record now says the turn stopped. Its turn was committed
    /// too when it could be; a turn commit that failed, or a provider that
    /// records no turns, still ends here.
    case ended
    /// The record is not that wait any more (a prompt came, or it is
    /// gone). Nothing was written, and nothing will be for this wait.
    case movedOn
    /// The transcript no longer reads declined, or cannot be read.
    case notDeclined
    /// The record's lock could not be taken: a hook held it, or its lock
    /// file could not be opened or locked.
    case busy
    /// The request was refused, or the record could not be written.
    case failed
    /// This is a word a newer bridge added. We read it as a failure, which
    /// is tried again a bounded number of times.
    case unknown

    init(from decoder: any Decoder) throws {
        self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
    }

    /// Whether nothing is left to try for the wait.
    var isSettled: Bool {
        switch self {
        case .ended, .movedOn: true
        case .notDeclined, .busy, .failed, .unknown: false
        }
    }
}
