// ReviewDraftStore.swift
// Limpid — the review draft on disk, apart from the state it restores.

import Foundation
import OSLog

private let log = Logger.limpid("review.draft")

/// What one repository's review is between sessions: the comments, and which
/// files the reader has finished with.
struct ReviewDraft: Codable {
    /// Which shape the rest of the file is in.
    ///
    /// Still 1: the shape changed several times while this was built, and none
    /// of those were ever released, so there is no earlier version for anyone
    /// to hold — numbering the first shipped format 2 would describe a history
    /// that did not happen. What it buys is the next change: a key that is
    /// renamed or nested fails to decode on its own, but one that is merely
    /// bundled into a new optional would read as absent, and every multi-line
    /// comment in an old draft would quietly become a single-line one. Bumping
    /// this turns that silence into a refusal the reader can see.
    var version = 1
    var comments: [ReviewComment] = []
    /// Optional because synthesized decoding does not fall back to a
    /// property's default value: a draft written before marks existed has no
    /// key here, and a non-optional would refuse the whole file.
    var viewed: [String: ReviewViewMark]?
    /// The file the reader had open, so reopening review returns to it.
    ///
    /// Beside the read marks because it is the same kind of thing: where this
    /// reader had got to in this worktree. Closing review is one keystroke and
    /// an insert does it too, and coming back to the top of the first changed
    /// file meant finding your place again by hand every time — a real cost in
    /// a fifty-file branch, where the file you were in is the whole context.
    ///
    /// Optional for the same reason `viewed` is, and only ever a hint: the
    /// file may be gone by the time it is read back, in which case the first
    /// changed file answers as before.
    var lastFileID: String?
}

/// Reading and writing a draft, named so the store can be exercised without a
/// filesystem and so the file format can change without touching the state
/// machine that produces it.
protocol ReviewDraftStoring: Sendable {
    /// The draft for this repository, or `nil` when there is none. Throws when
    /// one exists and cannot be trusted — the caller starts empty and says so.
    func load(root: URL) throws -> ReviewDraft?
    func save(_ draft: ReviewDraft, root: URL) throws
}

/// The draft as a file under the reviews directory, one per repository.
struct FileReviewDraftStore: ReviewDraftStoring {
    let directory: URL

    /// The cap `load` refuses, applied on the way out as well: a draft written
    /// past it is one this app will not read back, and every caller that can
    /// grow the unresolved count already answers for that with a message of
    /// its own.
    static let maxComments = 100
    static let maxBytes = 2 * 1024 * 1024

    /// Where a repository's draft is kept. Static so the deletion path can
    /// name it without a store: the reader deleting a worktree is not
    /// reviewing it.
    static func url(root: URL, directory: URL) -> URL {
        directory.appendingPathComponent(
            ReviewDiff.hash(Data(root.resolvingSymlinksInPath().path.utf8)) + ".json"
        )
    }

    func load(root: URL) throws -> ReviewDraft? {
        let file = Self.url(root: root, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
            guard data.count <= Self.maxBytes else { throw ReviewError.storageFailed }
            // Paired with `makeEncoder`, which writes dates as ISO 8601. A
            // bare decoder read every draft correctly until a comment first
            // carried a date, and then read none of them.
            let draft = try PersistenceCoders.makeDecoder().decode(ReviewDraft.self, from: data)
            // Against the unresolved count, the same as `add` — a draft whose
            // resolved comments had grown past the cap would otherwise be
            // refused whole on the next launch, which reads as the drafts
            // having been lost.
            guard draft.version == 1,
                  draft.comments.count(where: { !$0.isResolved }) <= Self.maxComments
            else { throw ReviewError.storageFailed }
            // A run has to stay a run. Nothing else bounds what a file on disk
            // claims, and the row counts walk every id in the range, so one
            // corrupt end would hang the surface rather than fail it.
            guard draft.comments.allSatisfy({
                $0.lineID >= 0 && $0.lastLineID - $0.lineID <= ReviewDiffParser.maxRows
            }) else { throw ReviewError.storageFailed }
            return draft
        } catch {
            // Moved aside rather than kept, and saving stays on. Refusing to
            // save was meant to protect a draft we could not read, but nothing
            // ever turned it back on: one draft written past a limit locked
            // that repository out of review for good, with the only way back
            // being to find the file and delete it. The reader starts from an
            // empty draft and their bytes survive beside it, which is what
            // `SettingsStore` and `SessionStore` already do.
            Self.quarantine(at: file, reason: "decode-failed")
            throw ReviewError.storageFailed
        }
    }

    func save(_ draft: ReviewDraft, root: URL) throws {
        let file = Self.url(root: root, directory: directory)
        SecureFileWrite.ensureUserOnlyDirectory(file.deletingLastPathComponent())
        guard draft.comments.count(where: { !$0.isResolved }) <= Self.maxComments else {
            throw ReviewError.commentLimitReached
        }
        let data = try PersistenceCoders.makeEncoder().encode(draft)
        guard data.count <= Self.maxBytes else {
            throw draft.comments.contains(where: \.isResolved) ? ReviewError.resolvedBacklogTooLarge : ReviewError.storageFailed
        }
        try SecureFileWrite.writeAtomic(data, to: file)
    }

    /// Rename an unreadable draft to `<name>.bak-<reason>-<ts>` so the reader's
    /// own bytes outlive the fresh draft that replaces them. Best effort: a
    /// rename that fails leaves the file where it was, and the next write
    /// replaces it.
    private static func quarantine(at url: URL, reason: String) {
        let stamp = Int(Date().timeIntervalSince1970)
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".bak-\(reason)-\(stamp)")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            log.notice("quarantined review draft to \(backup.lastPathComponent, privacy: .public)")
        } catch {
            log.error("failed to quarantine review draft: \(String(describing: error), privacy: .private)")
        }
    }
}

/// A draft that lives only as long as the store holding it, for demo mode and
/// for tests that have nothing to say about the filesystem.
struct EphemeralReviewDraftStore: ReviewDraftStoring {
    func load(root _: URL) throws -> ReviewDraft? {
        nil
    }

    func save(_: ReviewDraft, root _: URL) throws {}
}

/// We serialize all draft writes and deletions on this queue. The snapshot
/// generation is protected by a separate lock so scheduling never waits on disk I/O.
/// Edits and deletions invalidate navigation snapshots before their asynchronous hop.
final class ReviewDraftWriteCoordinator: @unchecked Sendable {
    static let shared = ReviewDraftWriteCoordinator()
    private let queue = DispatchQueue(label: "dev.limpid.review.draft-write")
    private let generationLock = NSLock()
    private var generations: [URL: UUID] = [:]

    func beginNavigation(for root: URL) -> UUID {
        generationLock.withLock {
            let generation = UUID()
            generations[root] = generation
            return generation
        }
    }

    func save(_ draft: ReviewDraft, root: URL, storage: any ReviewDraftStoring) throws {
        try queue.sync {
            generationLock.withLock { generations[root] = UUID() }
            try storage.save(draft, root: root)
        }
    }

    func saveNavigation(
        _ draft: ReviewDraft, root: URL, storage: any ReviewDraftStoring, generation: UUID
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard self.generationLock.withLock({ self.generations[root] == generation }) else { return false }
                    try storage.save(draft, root: root)
                    return true
                })
            }
        }
    }

    func remove(root: URL, directory: URL) {
        queue.sync {
            generationLock.withLock { generations[root] = UUID() }
            try? FileManager.default.removeItem(at: FileReviewDraftStore.url(root: root, directory: directory))
        }
    }
}
