// ReviewDraftWriter.swift
// Weir — the one writer of a worktree's review draft, shared by every review of that worktree.

import Foundation

/// What a reader has done with one worktree's review: the comments, the read
/// marks, the file last open in each scope, the fixed ranges those belong to,
/// and which comments the worktree has moved past. One per root, shared by
/// every `ReviewSession` on it.
///
/// Split from what a view is showing because the two have different owners.
/// A comment written in one window is the same comment in another, and two
/// writers of one draft file would each save over the other's edit; but the
/// scope, the list and the open diff are a view's own, and sharing them made
/// two windows reviewing the same worktree move each other's selection.
@MainActor
@Observable
final class ReviewDraftWriter {
    let root: URL
    private(set) var comments: [ReviewComment] = []
    /// Which files the reader has finished with, by scope ID
    /// (`ReviewScope.scopeID`) and then by `ReviewFile.id`.
    ///
    /// Kept beside the comments, in the same draft, because it is the same
    /// kind of thing: what this reader has done with this worktree, which no
    /// one else needs and which has to survive the window closing. By scope,
    /// because a file read in one comparison is not read in another: a
    /// turn's file read against its own snapshot says nothing about the next
    /// prompt's.
    private(set) var viewedByScope: [String: [String: ReviewViewMark]] = [:]
    /// The file the reader had open in each scope when this worktree was last
    /// reviewed.
    ///
    /// A hint, not a selection: a session reads it when a list first arrives,
    /// and `resumeFileID` is what decides whether it still names anything.
    private(set) var lastFileIDs: [String: String] = [:]
    /// The fixed ranges of turns this review has read, by scope ID, so a
    /// comment kept for one is checked against that range rather than the
    /// one on screen.
    private(set) var turnRanges: [String: ReviewTurnRange] = [:]
    /// The comments the worktree has moved past, as the last check of each
    /// found it. Shared because it is a fact about the comment and the
    /// repository, not about the view that happened to check: a comment one
    /// window found stale is held back from the other window's insert too.
    /// That holds only for a check made in the comment's own comparison, so
    /// sessions record a comment here only when they read it there
    /// (`ReviewSession.isCheckedHere`).
    private(set) var staleCommentIDs: Set<UUID> = []
    /// Whether the draft on disk could not be read when this writer opened.
    private(set) var hasUnreadableDraft = false
    /// Whether this writer must not write the draft: the file on disk could
    /// not be moved aside, or an older draft was brought forward without a
    /// copy of the original. The review works from memory, and says so; the
    /// pool holds writers weakly, so closing every review of the worktree
    /// drops those changes, and opening one again reads the file afresh.
    private(set) var isSavingSuspended = false

    /// The clock for read marks; injected by tests.
    @ObservationIgnored var now: () -> Date = Date.init

    /// Where the draft is kept. Injected so a test can keep it anywhere, and
    /// so the file format can change without touching the state above it.
    private let drafts: any ReviewDraftStoring
    /// The sessions reading this worktree, held weakly: what they have open
    /// is what the draft must keep (`openScopeIDs`), and a session that went
    /// away has nothing open.
    @ObservationIgnored private var sessions: [WeakSession] = []
    /// Present while navigation metadata is waiting to be persisted.
    @ObservationIgnored private var navigationSaveTask: Task<Void, Never>?
    @ObservationIgnored private var navigationGeneration = UUID()

    private final class WeakSession {
        weak var value: ReviewSession?
        init(_ value: ReviewSession) {
            self.value = value
        }
    }

    init(root: URL, drafts: any ReviewDraftStoring) {
        self.root = root.resolvingSymlinksInPath()
        self.drafts = drafts
        do {
            guard let draft = try drafts.load(root: self.root) else { return }
            apply(draft)
        } catch let ReviewDraftLoadError.migratedWithoutCopy(draft) {
            apply(draft)
            isSavingSuspended = true
        } catch ReviewDraftLoadError.keptInPlace {
            hasUnreadableDraft = true
            isSavingSuspended = true
        } catch {
            hasUnreadableDraft = true
        }
    }

    private func apply(_ draft: ReviewDraft) {
        comments = draft.allComments
        viewedByScope = draft.viewed
        lastFileIDs = draft.lastFileID
        turnRanges = Dictionary((draft.ranges ?? []).map { ($0.scopeID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The message no operation may clear while it holds.
    var standingDraftMessage: DisplayText? {
        switch (hasUnreadableDraft, isSavingSuspended) {
        case (true, true): DisplayText(error: ReviewError.draftUnreadableNotSaved)
        case (false, true): DisplayText(error: ReviewError.draftNotSaved)
        case (true, false): DisplayText(error: ReviewError.draftUnreadable)
        case (false, false): nil
        }
    }

    /// Records a range a session opened or extended to.
    func rememberRange(_ range: ReviewTurnRange) {
        turnRanges[range.scopeID] = range
    }

    /// Takes back a range remembered for a carry whose save failed.
    func forgetRange(_ scopeID: String) {
        turnRanges[scopeID] = nil
    }

    /// Records what one comment's check found.
    func setStale(_ id: UUID, _ isStale: Bool) {
        if isStale {
            staleCommentIDs.insert(id)
        } else {
            staleCommentIDs.remove(id)
        }
    }

    /// Records a check of several comments: `checked` were asked about,
    /// `valid` of them still hold. A comment not checked keeps what its last
    /// check found.
    func recordCheck(of checked: Set<UUID>, valid: Set<UUID>) {
        staleCommentIDs = staleCommentIDs.subtracting(checked).union(checked.subtracting(valid))
    }

    /// Takes comments just checked against their scope off the stale list.
    func markCurrent(_ ids: [UUID]) {
        staleCommentIDs.subtract(ids)
    }

    /// Registers a session reading this worktree.
    func attach(_ session: ReviewSession) {
        sessions = sessions.filter { $0.value != nil } + [WeakSession(session)]
    }

    /// The scopes some session has on screen. Their read marks never age out
    /// and their open file is kept, whichever window shows them.
    var openScopeIDs: Set<String> {
        Set(sessions.compactMap { $0.value?.scope.scopeID })
    }

    /// Writes the draft with `next` and, when given, every scope's marks.
    ///
    /// Throws without changing anything when the write fails, so the caller
    /// can keep the reader's text where it was. While saving is suspended the
    /// change is kept in memory only, under the banner that says so: writing
    /// would replace the only copy of what is on disk.
    func commit(_ next: [ReviewComment], viewed nextViewed: [String: [String: ReviewViewMark]]? = nil) throws {
        navigationSaveTask?.cancel()
        navigationGeneration = UUID()
        let marks = nextViewed ?? viewedByScope
        if !isSavingSuspended {
            do {
                try ReviewDraftWriteCoordinator.shared.save(makeDraft(comments: next, viewed: marks), root: root, storage: drafts)
            } catch let error as ReviewError {
                throw error
            } catch {
                throw ReviewError.storageFailed
            }
        }
        comments = next
        viewedByScope = marks
        staleCommentIDs.formIntersection(Set(next.map(\.id)))
    }

    /// Replaces every scope's read marks, saved soon rather than now: a mark
    /// is a hint the reader can make again, and they arrive with every list.
    func updateMarks(_ marks: [String: [String: ReviewViewMark]], report: @escaping @MainActor (ReviewError) -> Void) {
        viewedByScope = marks
        scheduleNavigationSave(report: report)
    }

    /// Records the file open in `scopeID`, so closing review and opening it
    /// again comes back there.
    func rememberOpenFile(_ fileID: String, in scopeID: String, report: @escaping @MainActor (ReviewError) -> Void) {
        guard lastFileIDs[scopeID] != fileID else { return }
        lastFileIDs[scopeID] = fileID
        scheduleNavigationSave(report: report)
    }

    /// Copies one scope's read marks to another ("Add to Scope"); the next
    /// list read drops those whose files moved since.
    func carryReadMarks(from scopeID: String, to nextScopeID: String) {
        guard let marks = viewedByScope[scopeID], viewedByScope[nextScopeID] == nil else { return }
        viewedByScope[nextScopeID] = marks
    }

    /// The draft to write: comments with a scope, the ones without as
    /// `legacy`, the marks of closed fixed scopes that have aged out left
    /// behind, and the open file only of scopes still worth going back to.
    func makeDraft(comments next: [ReviewComment], viewed marks: [String: [String: ReviewViewMark]]) -> ReviewDraft {
        let legacy = next.filter(\.scopeIDs.isEmpty)
        let open = openScopeIDs
        let kept = Self.pruned(marks, open: open, now: now())
        // A range is a scope of its own; without this the open file of every
        // range ever reviewed would stay in the draft.
        let scopesInUse = Set(kept.keys).union(next.flatMap(\.scopeIDs)).union(open)
        let ranges = turnRanges.filter { scopesInUse.contains($0.key) }.values.sorted { $0.scopeID < $1.scopeID }
        return ReviewDraft(
            comments: next.filter { !$0.scopeIDs.isEmpty },
            viewed: kept,
            lastFileID: lastFileIDs.filter { !Self.isFixedScope($0.key) || scopesInUse.contains($0.key) },
            legacy: legacy.isEmpty ? nil : legacy,
            ranges: ranges.isEmpty ? nil : ranges
        )
    }

    /// How long the read marks of a fixed scope no longer open are kept. A
    /// turn's comparison never changes: once the reader has moved on from it,
    /// its marks only matter for going back soon after.
    static let closedScopeMarkLifetime: TimeInterval = 14 * 24 * 60 * 60

    /// Whether `scopeID` names a fixed comparison (a range's snapshots)
    /// rather than one that follows the worktree (uncommitted changes, a
    /// branch), whose marks stay until their files move on, as they always
    /// have. `turn:` is the per-pane turn of earlier builds, which no review
    /// opens now: its marks in a saved draft go after the same lifetime.
    static func isFixedScope(_ scopeID: String) -> Bool {
        scopeID.hasPrefix("turn:") || scopeID.hasPrefix("turns:")
    }

    /// `marks` without those of closed fixed scopes older than
    /// `closedScopeMarkLifetime`. A mark with no date (kept from before dates
    /// were) stays until its file moves on. A scope any window has open is
    /// not closed.
    static func pruned(
        _ marks: [String: [String: ReviewViewMark]],
        open: Set<String>,
        now: Date
    ) -> [String: [String: ReviewViewMark]] {
        var kept: [String: [String: ReviewViewMark]] = [:]
        for (scopeID, fileMarks) in marks {
            let fresh = open.contains(scopeID) || !isFixedScope(scopeID) ? fileMarks : fileMarks.filter { _, mark in
                mark.markedAt.map { now.timeIntervalSince($0) <= closedScopeMarkLifetime } ?? true
            }
            if !fresh.isEmpty {
                kept[scopeID] = fresh
            }
        }
        return kept
    }

    /// Navigation is an optimistic hint. We coalesce it on a short timer and
    /// write it off the main actor; comment edits still wait for durable storage before closing the composer.
    private func scheduleNavigationSave(report: @escaping @MainActor (ReviewError) -> Void) {
        guard !isSavingSuspended else { return }
        navigationSaveTask?.cancel()
        let token = UUID()
        navigationGeneration = token
        let writeGeneration = ReviewDraftWriteCoordinator.shared.beginNavigation(for: root)
        // We retain the writer through this bounded save so closing review immediately
        // after selecting a file does not discard the pending navigation hint.
        navigationSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: PersistenceTiming.coalescing)
                try Task.checkCancellation()
                let snapshot = makeDraft(comments: comments, viewed: viewedByScope)
                _ = try await Self.writeNavigation(snapshot, root: root, storage: drafts, generation: writeGeneration)
            } catch is CancellationError {
                // A newer navigation or a synchronous edit owns persistence now.
            } catch {
                guard navigationGeneration == token, !Task.isCancelled else { return }
                report(error as? ReviewError ?? .storageFailed)
            }
        }
    }

    /// Forget the draft written against a worktree that is being deleted.
    ///
    /// Only on the explicit delete. A worktree that is merely unreachable — an
    /// external volume that is not mounted — comes back, and its comments
    /// should come back with it. Without this, a new worktree made at the same
    /// path inherited comments written about code that is gone.
    nonisolated static func removeDraft(root: URL, directory: URL = ReviewDraftWriterPool.defaultDirectory) {
        ReviewDraftWriteCoordinator.shared.remove(root: root.resolvingSymlinksInPath(), directory: directory)
    }

    private nonisolated static func writeNavigation(
        _ snapshot: ReviewDraft, root: URL, storage: any ReviewDraftStoring, generation: UUID
    ) async throws -> Bool {
        try await ReviewDraftWriteCoordinator.shared.saveNavigation(snapshot, root: root, storage: storage, generation: generation)
    }

    /// Wait for navigation metadata when verifying persistence across reopenings.
    func flushNavigationSave() async {
        await navigationSaveTask?.value
    }
}

/// Serialized with a lock rather than by isolating the type. The methods hand
/// back `@MainActor` objects and are only called from main-actor code, but the
/// pool is an `@Entry` default value, which SwiftUI builds outside any actor —
/// so the type itself cannot be `@MainActor`.
final class ReviewDraftWriterPool: @unchecked Sendable {
    /// Where the writers this pool hands out keep their drafts. In demo mode
    /// that is nowhere: `DemoFixture` is an app-level fact, so which one it is
    /// arrives from above rather than being read here.
    private let drafts: any ReviewDraftStoring

    /// Demo mode keeps its comments in memory: the fixture is a stage set, and
    /// writing its review into the reader's own draft directory would outlive
    /// the demo.
    init(shouldPersist: Bool = true, directory: URL? = nil) {
        drafts = shouldPersist
            ? FileReviewDraftStore(directory: directory ?? Self.defaultDirectory)
            : EphemeralReviewDraftStore()
    }

    private final class WeakWriter {
        weak var value: ReviewDraftWriter?
        init(_ value: ReviewDraftWriter) {
            self.value = value
        }
    }

    /// Where drafts live. Named here rather than at each use so the deletion
    /// path and the pool cannot end up looking in two places.
    static var defaultDirectory: URL {
        WeirPaths.applicationSupportDirectory().appendingPathComponent("reviews")
    }

    private let lock = NSLock()
    private var openWriters: [String: WeakWriter] = [:]

    /// The writer of `root`'s draft, shared while any session holds it.
    @MainActor
    func writer(root: URL) -> ReviewDraftWriter {
        let root = root.resolvingSymlinksInPath()
        if let existing = lock.withLock({
            openWriters = openWriters.filter { $0.value.value != nil }
            return openWriters[root.path]?.value
        }) {
            return existing
        }
        let writer = ReviewDraftWriter(root: root, drafts: drafts)
        lock.withLock { openWriters[root.path] = WeakWriter(writer) }
        return writer
    }

    /// Every fixed range of turns an open review has read or keeps
    /// comments for, which the retention sweep must not take.
    @MainActor
    func openTurnRanges() -> [ReviewTurnRange] {
        let writers = lock.withLock { openWriters.values.compactMap(\.value) }
        return writers.flatMap(\.turnRanges.values)
    }

    /// A new view of `root`'s review, writing through the shared writer.
    @MainActor
    func session(root: URL) -> ReviewSession {
        ReviewSession(writer: writer(root: root))
    }
}
