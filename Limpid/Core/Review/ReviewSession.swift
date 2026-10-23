// ReviewSession.swift
// Limpid — one view's review of a worktree: its scope, its list and the diff it has open.

import Foundation

/// What one review surface is showing, over the draft every surface on the
/// worktree shares (`ReviewDraftWriter`). Two windows reviewing the
/// same worktree each have one, so one can read a turn while the other reads
/// the branch, and neither moves the other's selection; a comment either
/// writes is the other's at once.
@MainActor
@Observable
final class ReviewSession {
    let root: URL
    /// The draft this view reads and writes, shared with every other view of
    /// the worktree.
    let writer: ReviewDraftWriter
    /// What the list is a list of. This view's own: another window on the
    /// same worktree can be reading another comparison.
    private(set) var scope: ReviewScope = .uncommitted
    /// The branch available to compare against, kept even while reading the
    /// worktree. Comments written on the branch have to stay validatable after
    /// the reader switches back, or switching views would age out everything
    /// written in the other one. `nil` in a repository with no branch to
    /// compare against, which is what hides the mode.
    private(set) var base: String?
    private(set) var files: [ReviewFile] = []
    /// How many times the file list has been read and published, whatever
    /// it held. What depends on the worktree as of the last read (the review
    /// tab's changes outside turns) follows this rather than the list, which
    /// stays the same when a listed file changes again.
    private(set) var listReadCount = 0
    /// Keyed by `ReviewFile.id`. Decoration for the list, so a failure to read
    /// it never fails the refresh that produced the list itself.
    private(set) var stats: [String: ReviewFileStat] = [:]
    /// Every comment on the worktree, whichever view wrote it.
    var comments: [ReviewComment] {
        writer.comments
    }

    /// The comments this view draws, counts, resolves in bulk, and inserts:
    /// only the scope on screen's, rather than every comment on the
    /// worktree. A fixed range names its files the same way as every other
    /// range, so without this a comment written in one range was drawn on
    /// the same path in another.
    var shownComments: [ReviewComment] {
        comments(inScope: scope.scopeID)
    }

    /// The last complete selected snapshot. It remains authoritative while a
    /// replacement loads or fails, so the rail never names code from an empty
    /// intermediate state.
    private(set) var diff: ReviewDiff?
    /// The comment being written, or an existing one being rewritten: the
    /// review's own rather than its surface's, so it lives as long as the
    /// review does. The supervision window's review tab keeps its review
    /// while the window shows another project (`ParkedReview`), and the
    /// comment with it; a surface drawn again reads it here. It follows the
    /// open file's diff as that changes under it (`show`).
    var composer = ReviewComposerState()
    /// A comment that could not follow the diff it was written on, or be
    /// shown at all: offered in the review's banner to copy or throw away,
    /// so typed text never goes unseen (`ReviewComposerFollow`).
    var unplacedComment: String?
    private(set) var isLoading = false
    /// Whether a change list has arrived, preventing a premature empty state
    /// before the first Git read completes.
    private(set) var hasLoaded = false
    /// Errors remain visible until the next explicit operation succeeds.
    /// Kept unresolved, so a banner already on screen switches with the
    /// display language; the pane draws it in the window's locale.
    private(set) var errorMessage: DisplayText?
    /// Whether the last change-list refresh failed. Loading a file or saving a
    /// comment says nothing about whether the list on screen is current, and
    /// letting either clear the message hid a failed refresh behind the first
    /// file that happened to open — leaving a stale list on screen with
    /// nothing saying so.
    private(set) var hasListRefreshFailed = false
    /// What that failed refresh said, kept so it can be put back.
    ///
    /// The flag alone was enough to stop an operation clearing the banner, but
    /// not to restore it: an operation that failed in between overwrote the
    /// message, and when that operation later succeeded the banner it left was
    /// the one that no longer applied.
    private var listRefreshMessage: DisplayText?
    /// Whether the draft on disk could not be read when the writer opened.
    ///
    /// Its own flag, like `hasListRefreshFailed`: the message is raised before
    /// the first refresh, and that refresh clears whatever it finds. Without
    /// this the reader saw an empty review and no reason for it, while their
    /// own bytes sat in a `.bak-` file beside it.
    var hasUnreadableDraft: Bool {
        writer.hasUnreadableDraft
    }

    /// Whether the draft must not be written (`ReviewDraftWriter.isSavingSuspended`).
    var isSavingSuspended: Bool {
        writer.isSavingSuspended
    }

    /// Whether the worktree has moved on since what is on screen was read.
    ///
    /// Raised by a poll rather than by a file-system watcher: the surface
    /// already asks Git exactly this question, and an agent writing a large
    /// edit produces events faster than they could be acted on — they would
    /// have to be debounced back into the one question anyway. Nothing
    /// reloads on its own. The ground moving under a comment being written is
    /// worse than a diff the reader knows is a few seconds old, so this only
    /// offers the refresh.
    private(set) var hasPendingChanges = false
    var staleCommentIDs: Set<UUID> {
        writer.staleCommentIDs
    }

    var viewedByScope: [String: [String: ReviewViewMark]] {
        writer.viewedByScope
    }

    var lastFileIDs: [String: String] {
        writer.lastFileIDs
    }

    var turnRanges: [String: ReviewTurnRange] {
        writer.turnRanges
    }

    /// The clock for read marks; injected by tests.
    var now: () -> Date {
        get { writer.now }
        set { writer.now = newValue }
    }

    /// The read marks of the scope on screen, keyed by `ReviewFile.id`.
    var viewed: [String: ReviewViewMark] {
        viewedByScope[scope.scopeID] ?? [:]
    }

    /// The file the reader had open in the scope on screen.
    var lastFileID: String? {
        lastFileIDs[scope.scopeID]
    }

    /// The open file's new side, whole, for unfolding context.
    ///
    /// Read once per file open and thrown away with it. Not persisted and not
    /// part of the diff: it is a copy of what is already on disk, and the
    /// moment it disagrees with the patch the patch is what the reader is
    /// commenting on.
    private(set) var source: [String] = []
    /// How far each gap in the open file has been unfolded. Cleared with the
    /// file, like a scroll position — where a reader unfolded a diff an hour
    /// ago is not a decision worth carrying back to them.
    private(set) var gapSpans: [Int: ReviewGapSpan] = [:]
    /// What the stacked diff has read of the other files.
    let stackLoader: ReviewStackLoader
    /// One generation per kind of load. With one shared between them, opening
    /// a file while the list was still refreshing would throw the list away —
    /// and the rail would go on showing what it had.
    private var listGeneration = UUID()
    private var diffGeneration = UUID()
    /// How many loads are in flight. `isLoading` is derived from it rather
    /// than cleared by whichever run finishes last: a run that is canceled,
    /// or overtaken by a newer one, returns early, and keying the spinner on
    /// that path left it turning with nothing running behind it.
    private var running = 0
    /// How this session asks the repository what changed. Injected so a test
    /// can answer without a real repository and without spawning processes.
    /// Not private only so the session's extensions in other files
    /// (`ReviewSession+Drafts.swift`, `ReviewSession+Insert.swift`) can ask
    /// it; nothing outside the session does.
    let git: any ReviewRepositoryReading

    init(
        writer: ReviewDraftWriter,
        git: any ReviewRepositoryReading = LiveReviewRepository()
    ) {
        root = writer.root
        self.writer = writer
        self.git = git
        stackLoader = ReviewStackLoader(git: git, root: writer.root)
        errorMessage = writer.standingDraftMessage
        writer.attach(self)
        stackLoader.openFileID = { [weak self] in self?.diff?.file.id }
        stackLoader.onPublish = { [weak self] diffs in self?.reconcileStacked(diffs) }
    }

    /// A session with a writer of its own, for tests. The app goes through
    /// `ReviewDraftWriterPool`, which keeps one writer per worktree.
    convenience init(
        root: URL,
        git: any ReviewRepositoryReading = LiveReviewRepository(),
        drafts: any ReviewDraftStoring
    ) {
        self.init(writer: ReviewDraftWriter(root: root, drafts: drafts), git: git)
    }

    /// Takes comments just checked against their scope off the stale list.
    func markCurrent(_ ids: [UUID]) {
        writer.markCurrent(ids)
    }

    /// Read what the repository offers to compare against. Separate from a
    /// refresh because it changes far more slowly than the diff does, and a
    /// failure to find one is not a failure to load the changes.
    func loadBase() async {
        guard base == nil else { return }
        // A failure leaves no base to offer, which the comparison menu
        // shows as such; the next open asks again.
        base = try? await git.defaultBase(at: root)
    }

    /// Loads a complete review snapshot and publishes it in one main-actor
    /// turn. The visible snapshot remains intact while Git works. Returns the
    /// file included in the committed snapshot, or `nil` for an empty result
    /// and for a failure that leaves the previous snapshot authoritative.
    func reload(scope nextScope: ReviewScope? = nil, selectedFileID: String?) async -> ReviewReloadResult {
        let targetScope = nextScope ?? scope
        let token = UUID()
        listGeneration = token
        diffGeneration = token
        running += 1
        isLoading = true
        defer {
            running -= 1
            isLoading = running > 0
        }
        do {
            let (latestFiles, latestStats) = try await listSnapshot(scope: targetScope)
            guard listGeneration == token, diffGeneration == token else { return .superseded }
            // The file last open in the scope being loaded, not the one on
            // screen until now.
            let selected = latestFiles.first { $0.id == selectedFileID }
                ?? latestFiles.first { $0.id == lastFileIDs[targetScope.scopeID] }
                ?? latestFiles.first
            let read = await beginStackRead(selected, scope: targetScope)
            let loadedDiff = try await loadDiff(
                for: selected,
                scope: targetScope,
                generation: token
            )
            guard listGeneration == token, diffGeneration == token else { return .superseded }
            if case let .turns(range) = targetScope {
                writer.rememberRange(range)
            }
            let isSameScope = targetScope == scope
            scope = targetScope
            files = latestFiles
            listReadCount += 1
            stats = latestStats
            retireStack(isSameScope: isSameScope, listed: latestFiles)
            show(loadedDiff.diff)
            if let latestDiff = loadedDiff.diff, let read {
                rememberInStack(latestDiff, read: read)
            }
            source = loadedDiff.source
            noteSourceInStack()
            gapSpans = [:]
            hasLoaded = true
            hasPendingChanges = false
            hasListRefreshFailed = false
            listRefreshMessage = nil
            applyFileLoadError(loadedDiff.error)
            pruneViewed()
            if let selected, let latestDiff = loadedDiff.diff {
                reconcileLoadedDiff(latestDiff, for: selected)
            }
            return .applied(selectedFileID: selected?.id)
        } catch is CancellationError {
            return .superseded
        } catch {
            guard listGeneration == token, diffGeneration == token else { return .superseded }
            hasLoaded = true
            hasListRefreshFailed = true
            listRefreshMessage = DisplayText(error: error)
            errorMessage = DisplayText(error: error)
            return .failed
        }
    }

    private func applyFileLoadError(_ error: (any Error)?) {
        if let error {
            errorMessage = DisplayText(error: error)
        } else {
            clearOperationError()
        }
    }

    func load(_ file: ReviewFile) async {
        let token = UUID()
        diffGeneration = token
        running += 1
        isLoading = true
        defer {
            running -= 1
            isLoading = running > 0
        }
        do {
            let read = await beginStackRead(file, scope: scopeForFile(file))
            var latest = try await git.diff(file, root: root, scope: scopeForFile(file))
            guard diffGeneration == token else { return }
            // The gutter is sized for the highest line number the file can ever show, which unfolding
            // takes past anything in the patch — and a width that arrived a
            // moment later rebuilt every row and slid the whole diff sideways
            // under a reader who had already started reading it.
            let intralinePairs = ReviewIntralineDiff.pairs(for: latest.lines)
            async let contentRead = git.source(file, root: root, scope: scopeForFile(file))
            async let intralineRead = ReviewIntralineDiff.computeOffActor(intralinePairs)
            latest.intralineHighlights = await intralineRead
            let content = await contentRead
            guard diffGeneration == token else { return }
            // Only the version the diff shows is unfolded (`ReviewSourceCheck`).
            source = ReviewSourceCheck.unfoldable(content, for: latest)
            noteSourceInStack()
            show(latest)
            if let read {
                rememberInStack(latest, read: read)
            }
            gapSpans = [:]
            clearOperationError()
            reconcileLoadedDiff(latest, for: file)
        } catch is CancellationError {
            // Another file took over, or the surface went away.
        } catch {
            guard diffGeneration == token else { return }
            errorMessage = DisplayText(error: error)
        }
    }

    /// Opens a file the review tab's stack has already read, at once, and
    /// answers the load's generation for `readSource`, in every comparison:
    /// the diff is the one the reader was looking at, and reading it
    /// again would swap what they were reading without a word. That the
    /// work tree has moved on since is the change check's to say, with its
    /// banner. `nil` for a file the stack has not read, or read before a
    /// refresh, which is loaded as `load` does.
    func openFromStack(_ file: ReviewFile) -> UUID? {
        guard let cached = stackLoader.entries[file.id]?.diff,
              !stackLoader.stale.contains(file.id)
        else { return nil }
        let token = UUID()
        diffGeneration = token
        show(cached)
        source = []
        gapSpans = [:]
        clearOperationError()
        reconcileLoadedDiff(cached, for: file)
        return token
    }

    // MARK: - The comment being written

    /// Opens `next` as the open file's diff, and has a comment being written
    /// follow it (`ReviewComposerFollow`): onto the same code, or, where it
    /// cannot go, into the banner with its text.
    private func show(_ next: ReviewDiff?) {
        let previous = diff
        diff = next
        let editedBody = composer.editingCommentID.flatMap { id in comments.first { $0.id == id }?.body }
        switch ReviewComposerFollow.outcome(of: composer, from: previous, to: next, editedBody: editedBody) {
        case .kept:
            break
        case let .moved(moved):
            composer = moved
        case .setAside:
            setComposerAside()
        case .closed:
            composer.cancel()
        }
    }

    /// The contents of a file opened from the stack, for unfolding, unless
    /// another file has been opened since.
    func readSource(of file: ReviewFile, generation: UUID) async {
        let content = await git.source(file, root: root, scope: scopeForFile(file))
        guard diffGeneration == generation, let diff, diff.file.id == file.id else { return }
        // Only the version the diff shows is unfolded; whether the file
        // changed is its fingerprint's to say, on the next poll.
        source = ReviewSourceCheck.unfoldable(content, for: diff)
        noteSourceInStack()
    }

    /// The open file's whole content sizes the stacked diff's one gutter,
    /// which keeps the widest the range has needed.
    private func noteSourceInStack() {
        stackLoader.noteLines(source.count)
    }

    /// Hands the stack the list just read, in `scope`. A fixed range of
    /// turns compares two trees, so a refresh of it changes nothing read,
    /// and nothing read of it needs watching for a change.
    private func retireStack(isSameScope: Bool, listed: [ReviewFile]) {
        var isFixedRange = false
        if case .turns = scope {
            isFixedRange = true
        }
        stackLoader.tracksContent = !isFixedRange
        let retirement: ReviewStackLoader.Retirement = switch (isSameScope, isFixedRange) {
        case (false, _): .anotherScope
        case (true, true): .sameRange
        case (true, false): .sameScope
        }
        stackLoader.retire(retirement, listed: listed)
    }

    /// Checks the comments and the read mark of a file against the diff
    /// read of it: the open file's, and each file the stack reads.
    func reconcileLoadedDiff(_ latest: ReviewDiff, for file: ReviewFile) {
        // A fixed comparison names its files the same way whichever turns it
        // compares (`turns:<path>`, `turn:<path>`), so only the comments
        // written in the one on screen are about this diff; another's are
        // checked against their own (`isCheckedHere`).
        for comment in comments where comment.file.id == file.id && isCheckedHere(comment) {
            // A comment can come back into date when the worktree is restored.
            writer.setStale(comment.id, comment.fingerprint != latest.fingerprint)
        }
        reconcileViewMark(for: file, against: latest.fingerprint)
    }

    /// Compares the worktree against what is displayed, and says so.
    ///
    /// Reads nothing into `files` or `diff` — a poll that updated them would
    /// be the auto-reload this exists to avoid. It gives up rather than
    /// competes: a load in flight is about to answer the same question, and
    /// once the banner is up there is nothing further to detect.
    func detectChanges() async {
        guard hasLoaded, running == 0, !hasPendingChanges else { return }
        // The same token the refreshes carry. `running == 0` only says nothing
        // is loading right now, so without it a refresh that started and
        // finished inside the wait below would leave this comparing its own
        // stale answer against the list that replaced it — and raising the
        // banner stops the poll, which would leave it up until the reader
        // refreshed by hand.
        let token = listGeneration
        let current = diff
        // A check Git could not answer raises nothing: the next poll asks
        // again, and a banner on a guess would send the reader to refresh.
        guard let hasChanges = try? await git.hasChanges(
            at: root,
            scope: scope,
            comparedTo: files,
            currentDiff: current
        ), running == 0, listGeneration == token
        else { return }
        // The same token again, for the same reason the comment above gives.
        // Carrying it only past the first await left this one able to answer
        // for a list that had been replaced while it waited: a worktree that
        // moves and moves back inside this wait, with a refresh in between,
        // ends here comparing the fingerprint it read against a diff that has
        // since been reloaded to match it — and raising the banner anyway.
        // Raising it stops the poll, so the banner then sits over a view that
        // is current until the reader refreshes by hand.
        guard running == 0, listGeneration == token, diff?.fingerprint == current?.fingerprint else { return }
        guard !hasChanges else {
            hasPendingChanges = true
            return
        }
        // The stacked diff draws every file it has read, so each of them is
        // asked the same question.
        guard await stackedFilesHaveChanged(), running == 0, listGeneration == token else { return }
        hasPendingChanges = true
    }

    /// Whether a file the stack has read, other than the open one, is not
    /// what it was when it was read: one read for all of them, as this runs
    /// on every poll and a range searched whole has hundreds. A fixed range
    /// of turns compares two trees and never changes. A file read before a
    /// refresh is not compared: it is drawn only until it is read again.
    private func stackedFilesHaveChanged() async -> Bool {
        if case .turns = scope {
            return false
        }
        return await stackLoader.hasChangedFiles(excluding: diff?.file.id, scope: scope)
    }

    /// Comment counts keyed by `ReviewFile.id`, so the list can show where
    /// feedback already exists without each row scanning every comment.
    var commentCounts: [String: Int] {
        shownComments.reduce(into: [:]) { counts, comment in
            guard !comment.isResolved else { return }
            counts[comment.file.id, default: 0] += 1
        }
    }

    @discardableResult
    func add(line: ReviewLine, body: String) -> Bool {
        add(lines: [line], side: nil, body: body)
    }

    /// A comment can cover a run of lines. Reviewers routinely mean a block —
    /// a whole guard, a whole added branch — and one comment per line loses
    /// both the point being made and the code it was made about.
    ///
    /// `side` is the column the run was selected in. The caller hands us the
    /// whole id range; a run selected in one column of the split layout covers
    /// only the lines that column draws, and filtering here is what keeps the
    /// quoted code and the line numbers to the ones the reader saw.
    @discardableResult
    func add(lines: [ReviewLine], side: ReviewSide?, body: String) -> Bool {
        // Held inside one changed block, whatever reached here. A comment
        // names a span of line numbers, and a run that crossed from one hunk
        // to the next would name every line between two places that are next
        // to each other on screen and hundreds of lines apart in the file.
        // The selection is stopped at the boundary as well; this is the last
        // line of defense, and it clamps rather than refuses because the
        // reader has nothing to answer here.
        let run = Self.commentRun(of: lines, side: side)
        // Nothing the reader can act on, so the composer closes: an empty run
        // or a diff that is gone is not a refusal they could answer.
        guard let diff, let span = ReviewAnchor.span(of: run) else { return true }
        // By id against a set, not by value against the array. `contains` on
        // `[ReviewLine]` compares whole lines once per line of the run, and a
        // hundred thousand of each is ten billion comparisons — most of them
        // settled by the id, but the ones that are not read the whole line
        // comparisons on the main thread.
        let known = Set(diff.lines.lazy.map(\.id))
        guard run.allSatisfy({ known.contains($0.id) }) else { return true }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A guard each, so a reader who hits the comment limit is not told
        // their text holds control characters. An empty body returns without
        // a message: the composer refuses to commit one, so there is nothing
        // for the reader to act on.
        guard !text.isEmpty else { return true }
        guard comments.count(where: { !$0.isResolved }) < Self.maxComments else {
            errorMessage = DisplayText(error: ReviewError.commentLimitReached)
            return false
        }
        guard text.utf8.count <= Self.maxCommentBytes else {
            errorMessage = DisplayText(error: ReviewError.commentTooLong)
            return false
        }
        do { try ReviewPromptBuilder.validate(text) } catch {
            errorMessage = DisplayText(error: error)
            return false
        }
        let excerpt = Self.excerpt(of: run)
        let comment = ReviewComment(
            scopeIDs: [scope.scopeID],
            file: diff.file,
            fingerprint: diff.fingerprint,
            anchor: span.anchor,
            end: span.end,
            side: side,
            // Truncated together, so a marker always names the line above it.
            // Counted in lines rather than characters: cutting the excerpt
            // mid-line would leave the last marker describing half a line.
            code: excerpt.text,
            codeMarkers: excerpt.markers,
            body: text
        )
        return commit(comments + [comment])
    }

    /// Whether the edit was saved. A refusal the reader can act on — too long,
    /// characters that cannot be sent, a draft that would not write — keeps the
    /// composer open with their text. The early returns that say nothing
    /// answer `true`: nothing is wrong the reader could fix, and a composer
    /// left open with no message beside it is worse than one that closes.
    @discardableResult
    func edit(_ id: UUID, body: String) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard text.utf8.count <= Self.maxCommentBytes else {
            errorMessage = DisplayText(error: ReviewError.commentTooLong)
            return false
        }
        do { try ReviewPromptBuilder.validate(text) } catch {
            errorMessage = DisplayText(error: error)
            return false
        }
        var next = comments
        guard let index = next.firstIndex(where: { $0.id == id }) else {
            // Gone from the shared draft (deleted in another window): saying
            // so keeps the composer open with the reader's text in it, where
            // closing quietly would throw it away.
            errorMessage = DisplayText(error: ReviewError.commentDeletedElsewhere)
            return false
        }
        next[index].body = text
        return commit(next)
    }

    func remove(_ id: UUID) {
        commit(comments.filter { $0.id != id })
    }

    /// Unfolds part of a gap.
    ///
    /// Clamped to what the gap holds so the two ends cannot pass each other,
    /// and a no-op without the file's content: there is nothing to draw.
    func expand(_ gap: Int, _ action: ReviewGapAction) {
        guard action != .collapse else {
            gapSpans[gap] = nil
            return
        }
        guard !source.isEmpty, let total = gaps.first(where: { $0.index == gap })?.range.count else { return }
        var span = gapSpans[gap] ?? ReviewGapSpan()
        let shown = min(span.above, total) + min(span.below, total)
        let remaining = max(total - shown, 0)
        guard remaining > 0 else { return }
        switch action {
        case .up:
            span.above = min(span.above, total) + min(ReviewExpansionPlan.step, remaining)
        case .down:
            span.below = min(span.below, total) + min(ReviewExpansionPlan.step, remaining)
        case .all:
            span.below = total
            span.above = 0
        case .collapse:
            break
        }
        gapSpans[gap] = span
    }

    /// Records where the reader is, so closing review and opening it again
    /// comes back here.
    ///
    /// Navigation is an optimistic hint. We coalesce it off the main actor;
    /// comment edits still wait for durable storage before closing the composer.
    func rememberOpenFile(_ fileID: String?) {
        guard let fileID else { return }
        writer.rememberOpenFile(fileID, in: scope.scopeID, report: reportNavigationFailure)
    }

    /// Marks a file read, or puts it back.
    ///
    /// Takes the stat from the list rather than asking Git, so marking is
    /// instant and works on a file that has never been opened. The fingerprint
    /// comes along only when the file is the one on screen — it is what
    /// catches an edit the counts cannot see, and there is nothing to compare
    /// against for a file the reader only glanced at in the list.
    func setViewed(_ fileID: String, _ isViewed: Bool) {
        var marks = viewed
        if isViewed {
            let stat = stats[fileID]
            marks[fileID] = ReviewViewMark(
                added: stat?.added ?? 0,
                removed: stat?.removed ?? 0,
                fingerprint: diff?.file.id == fileID ? diff?.fingerprint : nil,
                markedAt: now()
            )
        } else {
            marks.removeValue(forKey: fileID)
        }
        guard marks != viewed else { return }
        commit(comments, viewed: marks)
    }

    /// Brings one file's read mark up to date with the diff now on screen.
    ///
    /// A mark made from the list has no fingerprint behind it: nothing was
    /// read to produce one. Opening the file is the first chance to record it,
    /// and from then on a change the counts cannot see takes the mark off.
    private func reconcileViewMark(for file: ReviewFile, against fingerprint: String) {
        guard let mark = viewed[file.id] else { return }
        guard let known = mark.fingerprint else {
            var marks = viewed
            marks[file.id] = ReviewViewMark(
                added: mark.added,
                removed: mark.removed,
                fingerprint: fingerprint,
                markedAt: mark.markedAt
            )
            updateNavigationMarks(marks)
            return
        }
        guard known != fingerprint else { return }
        updateNavigationMarks(viewed.filter { $0.key != file.id })
    }

    /// Drops the marks the change list has moved past.
    ///
    /// A file that left the list is not read — it is gone, and if it comes
    /// back it is new work. A file whose counts moved has been edited since
    /// the reader finished with it, which is the whole point of the mark.
    ///
    /// Only within the scope being shown: the marks are kept by scope, and a
    /// scope-blind prune read "not in this list" as "gone" for every mark
    /// another scope had made.
    private func pruneViewed() {
        let listed = Set(files.map(\.id))
        let kept = viewed.filter { id, mark in
            guard listed.contains(id) else { return false }
            // Git reports no counts for an untracked file, so there is nothing
            // here to compare and the mark rests on the fingerprint alone.
            guard let stat = stats[id] else { return true }
            return stat.added == mark.added && stat.removed == mark.removed
        }
        guard kept != viewed else { return }
        updateNavigationMarks(kept)
    }

    /// Records that these comments reached an agent.
    ///
    /// Called with what was sent rather than with everything on screen: a
    /// stale comment is held back from the prompt, and marking it delivered
    /// would tell the reader it had been asked for when it never was.
    /// Answers whether the record was written. A failure here is not a failed
    /// delivery — the text has already reached the agent — but the review must
    /// not close over it: reopened, those comments would read as never sent,
    /// and the reader would send them a second time.
    ///
    /// Each comment is marked only while it still reads as it was sent. The
    /// draft is shared with every review of the worktree, and another window
    /// can edit a comment while this insert waits on the paste's answer: the
    /// agent got the text from before that edit, so the edited one was never
    /// asked for. Answers how many were left unmarked for that reason, which
    /// keeps the review open on them.
    @discardableResult
    func markInserted(_ sent: [ReviewComment], at date: Date = Date()) -> (changed: Int, wasRecorded: Bool) {
        let sentByID = Dictionary(sent.map { ($0.id, $0) }) { first, _ in first }
        var next = comments
        var changed = 0
        var isMarking = false
        for index in next.indices {
            guard let version = sentByID[next[index].id] else { continue }
            guard next[index].readsAsSent(version) else {
                changed += 1
                continue
            }
            next[index].insertedAt = date
            isMarking = true
        }
        guard isMarking else { return (changed, true) }
        commit(next)
        return (changed, comments == next)
    }

    func setResolved(_ id: UUID, _ isResolved: Bool, at date: Date = Date()) {
        var next = comments
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        // Unresolving adds to the unresolved count, so it answers to the same
        // cap `add` does. Without this a draft could be written past the limit
        // that `init` refuses to load, which took the whole draft with it.
        if !isResolved, next[index].isResolved {
            guard next.count(where: { !$0.isResolved }) < Self.maxComments else {
                errorMessage = DisplayText(error: ReviewError.commentLimitReached)
                return
            }
        }
        next[index].resolvedAt = isResolved ? date : nil
        commit(next)
    }

    /// Resolves every comment the worktree has moved past, and answers with the
    /// draft as it was.
    ///
    /// Stale is the one bulk criterion that holds: those comments are already
    /// out of the prompt, so resolving them changes what the reader sees and
    /// not what an agent receives. The previous draft comes back for undo
    /// because judging a dozen comments handled at once is a decision worth
    /// being able to take back.
    @discardableResult
    func resolveStale(at date: Date = Date()) -> [ReviewComment]? {
        // Only the ones this view shows: another range's stale comments are
        // that range's to judge.
        let ids = staleCommentIDs.intersection(shownComments.map(\.id))
        let previous = comments
        guard previous.contains(where: { ids.contains($0.id) && !$0.isResolved }) else { return nil }
        var next = previous
        for index in next.indices where ids.contains(next[index].id) {
            next[index].resolvedAt = next[index].resolvedAt ?? date
        }
        commit(next)
        return comments == next ? previous : nil
    }

    /// Puts a draft back the way it was, for undo. Restores nothing if the
    /// reader has changed the review since — their newer edit outranks a
    /// five-second-old toast.
    func restore(_ previous: [ReviewComment], from expected: [ReviewComment]) {
        guard comments == expected else { return }
        commit(previous)
    }

    /// The list and its statistics, read side by side. The statistics are
    /// decoration (`stats`), so failing to count them fails nothing.
    private func listSnapshot(scope: ReviewScope) async throws -> ([ReviewFile], [String: ReviewFileStat]) {
        async let files = git.files(at: root, scope: scope)
        async let stats = try? git.stats(at: root, scope: scope)
        return try await (files, stats ?? [:])
    }

    /// Takes the banner down ahead of an operation the reader has just asked
    /// for, so what they read afterwards belongs to that operation.
    ///
    /// The quarantine notice survives: it is not about any one operation, and
    /// nothing but a readable draft answers it. Callers outside the session go
    /// through here rather than assigning the message themselves: assigning
    /// it is what let a refresh clear that notice and leave the reader with
    /// no sign that their comments were set aside.
    func clearError() {
        errorMessage = standingDraftMessage
    }

    /// Puts a failure the surface handled — building the prompt, reaching the
    /// pane — where the same banner can carry it, since to the reader it is
    /// the review that did not work.
    func report(_ error: any Error) {
        errorMessage = DisplayText(error: error)
    }

    /// Clears the message an operation is entitled to clear, and puts back the
    /// one it is not.
    ///
    /// A failed change list and an unreadable draft are both messages no
    /// operation may clear: only another refresh, or a readable draft, answers
    /// them. Leaving the banner alone while either stands is not the same
    /// thing as restoring them: an operation that failed in between has
    /// already overwritten the banner, so a later success would leave its own
    /// resolved error on screen and the standing message would never come
    /// back.
    private func clearOperationError() {
        if let listRefreshMessage {
            errorMessage = listRefreshMessage
            return
        }
        errorMessage = standingDraftMessage
    }

    private func updateNavigationMarks(_ marks: [String: ReviewViewMark]) {
        writer.updateMarks(withMarks(marks), report: reportNavigationFailure)
    }

    /// Where a navigation save that failed says so: the view that moved.
    /// Another view's hint can ride on the same coalesced save, and its
    /// failure is then told here only; it is a hint, made again by the next
    /// move.
    private var reportNavigationFailure: @MainActor (ReviewError) -> Void {
        { [weak self] error in self?.errorMessage = DisplayText(error: error) }
    }

    /// Wait for navigation metadata when verifying persistence across reopenings.
    func flushNavigationSave() async {
        await writer.flushNavigationSave()
    }

    /// Whether the draft was written. The composer asks so it can stay open
    /// with the reader's text in it when it was not — closing on a failed save
    /// threw away what they had just written, with only a banner to say why.
    /// Not private only for the scope operations in `ReviewSession+Drafts.swift`.
    @discardableResult
    func commit(_ next: [ReviewComment], viewed nextViewed: [String: ReviewViewMark]? = nil) -> Bool {
        do {
            try writer.commit(next, viewed: nextViewed.map(withMarks))
            clearOperationError()
            return true
        } catch {
            errorMessage = DisplayText(error: error as? ReviewError ?? .storageFailed)
            return false
        }
    }

}

private extension ReviewSession {
    /// Reads the selected file without letting a recoverable file failure
    /// discard the complete list that Git already returned.
    func loadDiff(
        for selected: ReviewFile?,
        scope: ReviewScope,
        generation: UUID
    ) async throws -> ReviewLoadedDiff {
        guard let selected else { return ReviewLoadedDiff(diff: nil, source: [], error: nil) }
        do {
            var latestDiff = try await git.diff(selected, root: root, scope: scope)
            guard listGeneration == generation, diffGeneration == generation else { throw CancellationError() }
            let intralinePairs = ReviewIntralineDiff.pairs(for: latestDiff.lines)
            async let sourceRead = git.source(selected, root: root, scope: scope)
            async let intralineRead = ReviewIntralineDiff.computeOffActor(intralinePairs)
            let source = await sourceRead
            latestDiff.intralineHighlights = await intralineRead
            guard listGeneration == generation, diffGeneration == generation else { throw CancellationError() }
            return ReviewLoadedDiff(diff: latestDiff, source: ReviewSourceCheck.unfoldable(source, for: latestDiff), error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard listGeneration == generation, diffGeneration == generation else { throw CancellationError() }
            return ReviewLoadedDiff(diff: nil, source: [], error: error)
        }
    }
}
