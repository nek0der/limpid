// ViewedLineRefs.swift
// Weir — keeps refs/weir/reviewed/<conversation hash> on the tree the viewed line stands at.

import CryptoKit
import Foundation
import OSLog
import WeirDomain

private let log = Logger.weir("viewed.refs")

/// Moves a conversation's auxiliary ref as its viewed line moves.
protocol ViewedLineRefWriting: Sendable {
    func move(_ conversation: ConversationKey, from: SnapshotTree?, to: SnapshotTree?)
    /// Returns once every move handed over so far is written, or after a
    /// short wait when git does not answer.
    func waitForPendingMoves()
}

/// The ref beside a viewed line: `refs/weir/reviewed/<conversation hash>`
/// points at the tree the line's turn ended at.
///
/// An auxiliary, never what decides what is viewed (the line is held by turn
/// ID). It keeps that tree reachable after the turn's own refs are deleted,
/// so restoring the code to the viewed state still has it; a line whose turn
/// has no end snapshot has no ref. Writes go out in order on one queue, so an
/// undo right after a move lands after it; a failed write is logged and
/// costs only the auxiliary.
struct ViewedLineRefs: ViewedLineRefWriting {
    private static let queue = DispatchQueue(label: "com.nekoder.weir.viewed-refs")

    /// The ref of `conversation`. Hashed, since a conversation ID is not
    /// known to be a valid ref name.
    static func refName(of conversation: ConversationKey) -> String {
        let key = "\(conversation.provider.rawValue)\n\(conversation.conversationID)\n\(conversation.isFallback)"
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return "refs/weir/reviewed/\(hash)"
    }

    func move(_ conversation: ConversationKey, from: SnapshotTree?, to: SnapshotTree?) {
        let ref = Self.refName(of: conversation)
        Self.queue.async {
            Self.apply(ref: ref, from: from, to: to)
        }
    }

    /// Bounded: the ref is an auxiliary, and quitting must not hang on a
    /// git that does (a work tree on a volume that went away).
    func waitForPendingMoves() {
        let isDone = DispatchSemaphore(value: 0)
        Self.queue.async { isDone.signal() }
        _ = isDone.wait(timeout: .now() + .seconds(2))
    }

    private static func apply(ref: String, from: SnapshotTree?, to: SnapshotTree?) {
        // The line left a work tree of another repository, or has no tree
        // now: the ref there goes, so it does not hold a tree nothing reads.
        if let from, from.root != to?.root {
            run(["update-ref", "-d", ref], in: from.root)
        }
        if let to {
            run(["update-ref", ref, to.tree], in: to.root)
        }
    }

    private static func run(_ arguments: [String], in root: String) {
        do {
            let result = try GitProcess.runSync(arguments, cwd: URL(fileURLWithPath: root, isDirectory: true))
            if !result.succeeded {
                let command = arguments.first ?? ""
                log.error("viewed ref: git \(command, privacy: .public) exited \(result.exitCode): \(result.stderr, privacy: .private)")
            }
        } catch {
            log.error("viewed ref: \(String(describing: error), privacy: .private)")
        }
    }
}
