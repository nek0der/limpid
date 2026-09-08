// ReviewStore.swift
// Limpid — bounded review drafts and immutable per-file review snapshots.

import Foundation
import OSLog

private let log = Logger.limpid("review.store")

@MainActor
@Observable
final class ReviewStore {
    let root: URL
    /// What the list is a list of. Per store rather than per window: the
    /// branch it compares against belongs to the repository, not to how the
    /// reader likes to read.
    private(set) var scope: ReviewScope = .uncommitted
    /// The branch available to compare against, kept even while reading the
    /// worktree. Comments written on the branch have to stay validatable after
    /// the reader switches back, or switching views would age out everything
    /// written in the other one. `nil` in a repository with no branch to
    /// compare against, which is what hides the mode.
    private(set) var base: String?
    private(set) var files: [ReviewFile] = []
    /// Keyed by `ReviewFile.id`. Decoration for the list, so a failure to read
    /// it never fails the refresh that produced the list itself.
    private(set) var stats: [String: ReviewFileStat] = [:]
    private(set) var comments: [ReviewComment] = []
    /// No snapshot is selected while a file is loading or after a failed read.
    private(set) var diff: ReviewDiff?
    private(set) var isLoading = false
    /// Whether a change list has come back yet. A store that has just been
    /// created has no files and is not loading, and for that one frame the
    /// surface said "No changes to review." over a repository full of them.
    private(set) var hasLoaded = false
    /// Errors remain visible until the next explicit operation succeeds.
    private(set) var errorMessage: String?
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
    private var listRefreshMessage: String?
    /// Whether the draft on disk could not be read when this store opened.
    ///
    /// Its own flag, like `hasListRefreshFailed`: the message is raised before
    /// the first refresh, and that refresh clears whatever it finds. Without
    /// this the reader saw an empty review and no reason for it, while their
    /// own bytes sat in a `.bak-` file beside it.
    private(set) var hasUnreadableDraft = false
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
    private(set) var staleCommentIDs: Set<UUID> = []
    /// Which files the reader has finished with, keyed by `ReviewFile.id`.
    ///
    /// Kept beside the comments, in the same draft, because it is the same
    /// kind of thing: what this reader has done with this worktree, which no
    /// one else needs and which has to survive the window closing.
    private(set) var viewed: [String: ReviewViewMark] = [:]
    /// The file the reader had open when this worktree was last reviewed.
    ///
    /// A hint, not a selection: it is read once, when the list first arrives,
    /// and `resumeFileID` is what decides whether it still names anything.
    private(set) var lastFileID: String?
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
    /// One generation per kind of load. They used to share one, so opening a
    /// file while the list was still refreshing threw the list away — and the
    /// rail went on showing what it had.
    private var listGeneration = UUID()
    private var diffGeneration = UUID()
    /// How many loads are in flight. `isLoading` is derived from it rather
    /// than cleared by whichever run finishes last: a run that is canceled,
    /// or overtaken by a newer one, returns early, and keying the spinner on
    /// that path left it turning with nothing running behind it.
    private var running = 0
    /// How this store asks the repository what changed. Injected so a test can
    /// answer without a real repository and without spawning processes.
    private let git: any ReviewRepositoryReading
    /// Where the draft is kept. Injected for the same reason, and so the file
    /// format can change without touching the state machine above it.
    private let drafts: any ReviewDraftStoring
    /// Present while navigation metadata is waiting to be persisted.
    private var navigationSaveTask: Task<Void, Never>?
    private var navigationGeneration = UUID()

    /// `nonisolated` so the off-actor write helper answers to the same cap the
    /// reader does; a draft written past it is one `init` refuses to load.
    nonisolated static let maxComments = 100
    nonisolated static let maxCommentBytes = 4096
    /// The excerpt is context for the agent, not the diff itself; a long run
    /// is quoted up to here and the prompt points at the line numbers.
    nonisolated static let maxCodeExcerpt = 2048
    init(
        root: URL,
        git: any ReviewRepositoryReading = LiveReviewRepository(),
        drafts: any ReviewDraftStoring
    ) {
        self.root = root.resolvingSymlinksInPath()
        self.git = git
        self.drafts = drafts
        do {
            guard let draft = try self.drafts.load(root: self.root) else { return }
            comments = draft.comments
            viewed = draft.viewed ?? [:]
            lastFileID = draft.lastFileID
        } catch {
            errorMessage = ReviewError.draftUnreadable.localizedDescription
            hasUnreadableDraft = true
        }
    }

    /// Forget the draft written against a worktree that is being deleted.
    ///
    /// Only on the explicit delete. A worktree that is merely unreachable — an
    /// external volume that is not mounted — comes back, and its comments
    /// should come back with it. Without this, a new worktree made at the same
    /// path inherited comments written about code that is gone.
    nonisolated static func removeDraft(root: URL, directory: URL = ReviewStorePool.defaultDirectory) {
        ReviewDraftWriteCoordinator.shared.remove(root: root.resolvingSymlinksInPath(), directory: directory)
    }

    /// Read what the repository offers to compare against. Separate from a
    /// refresh because it changes far more slowly than the diff does, and a
    /// failure to find one is not a failure to load the changes.
    func loadBase() async {
        guard base == nil else { return }
        base = try? await git.defaultBase(at: root)
    }

    /// Changing what the review is of invalidates anything in flight: a diff
    /// read for the old scope must not land on the new one's list.
    func setScope(_ next: ReviewScope) async {
        guard next != scope else { return }
        scope = next
        // A file load already in flight was started against the old scope and
        // would write its diff over the new scope's list when it lands. The
        // token it compares against is the one that says so.
        diffGeneration = UUID()
        diff = nil
        source = []
        gapSpans = [:]
        files = []
        hasLoaded = false
        await refresh()
    }

    func refresh() async {
        let token = UUID()
        listGeneration = token
        running += 1
        isLoading = true
        defer {
            running -= 1
            isLoading = running > 0
        }
        do {
            let latest = try await git.files(at: root, scope: scope)
            guard listGeneration == token else { return }
            hasLoaded = true
            files = latest
            hasPendingChanges = false
            hasListRefreshFailed = false
            listRefreshMessage = nil
            // Not the draft's message: a list that loaded says nothing about
            // the comments that could not be read, and clearing it took the
            // only notice of them off the screen.
            if !hasUnreadableDraft {
                errorMessage = nil
            }
            let latestStats = try? await git.stats(at: root, scope: scope)
            guard listGeneration == token else { return }
            stats = latestStats ?? [:]
            pruneViewed()
        } catch is CancellationError {
            // A newer refresh took over, or the surface went away. Neither is
            // something to report, and the list on screen still belongs to the
            // run that put it there.
        } catch {
            guard listGeneration == token else { return }
            hasLoaded = true
            hasListRefreshFailed = true
            listRefreshMessage = error.localizedDescription
            errorMessage = error.localizedDescription
        }
    }

    func load(_ file: ReviewFile) async {
        let token = UUID()
        diffGeneration = token
        running += 1
        isLoading = true
        diff = nil
        source = []
        gapSpans = [:]
        defer {
            running -= 1
            isLoading = running > 0
        }
        do {
            let latest = try await git.diff(file, root: root, base: base)
            guard diffGeneration == token else { return }
            // Before the diff is published, not after. The gutter is sized for
            // the highest line number the file can ever show, which unfolding
            // takes past anything in the patch — and a width that arrived a
            // moment later rebuilt every row and slid the whole diff sideways
            // under a reader who had already started reading it.
            let content = await git.source(file, root: root)
            guard diffGeneration == token else { return }
            source = content
            diff = latest
            clearOperationError()
            for comment in comments where comment.file.id == file.id {
                // Both directions: a comment can come back into date when the
                // worktree is put back the way it was, and one that stayed
                // marked would keep being held out of the prompt.
                if comment.fingerprint == latest.fingerprint {
                    staleCommentIDs.remove(comment.id)
                } else {
                    staleCommentIDs.insert(comment.id)
                }
            }
            // After the error is cleared, so a draft that cannot be written
            // still says so. The counts can sit still while the content moves,
            // which makes opening the file the moment to check its mark
            // against the diff the reader is actually looking at — and the
            // moment to record a fingerprint for a mark made from the list,
            // which has never had one to compare.
            reconcileViewMark(for: file, against: latest.fingerprint)
        } catch is CancellationError {
            // Another file took over, or the surface went away.
        } catch {
            guard diffGeneration == token else { return }
            errorMessage = error.localizedDescription
        }
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
        // is loading right now, so a refresh that started and finished inside
        // the wait below left this comparing its own stale answer against the
        // list that replaced it — and raising the banner stopped the poll,
        // which left it up until the reader refreshed by hand.
        let token = listGeneration
        guard let latest = try? await git.files(at: root, scope: scope),
              running == 0, listGeneration == token
        else { return }
        guard latest == files else {
            hasPendingChanges = true
            return
        }
        // The open file is the one being read and commented on, so its
        // content is worth a second call; the rest of the list is covered by
        // the names and statuses above.
        // The fingerprint alone: this runs on a timer, and building the rows to
        // throw them away parses the whole patch and walks every line of it.
        guard let current = diff,
              let latest = try? await git.fingerprint(current.file, root: root, base: base)
        else { return }
        // The same token again, for the same reason the comment above gives.
        // Carrying it only past the first await left this one able to answer
        // for a list that had been replaced while it waited: a worktree that
        // moves and moves back inside this wait, with a refresh in between,
        // ends here comparing the fingerprint it read against a diff that has
        // since been reloaded to match it — and raising the banner anyway.
        // Raising it stops the poll, so the banner then sits over a view that
        // is current until the reader refreshes by hand.
        guard running == 0, listGeneration == token, diff?.fingerprint == current.fingerprint else { return }
        hasPendingChanges = latest != current.fingerprint
    }

    /// The comments an insert would carry right now.
    ///
    /// Two conditions, and both live here: resolved is the reader's own
    /// decision, stale is what the worktree did to them. The surface, the
    /// preview and its per-file counts all have to answer the same question,
    /// and they were each answering it in their own words.
    var insertableComments: [ReviewComment] {
        comments.filter { !$0.isResolved && !staleCommentIDs.contains($0.id) }
    }

    /// Whether this comment would go into the next insert.
    func isInsertable(_ comment: ReviewComment) -> Bool {
        !comment.isResolved && !staleCommentIDs.contains(comment.id)
    }

    /// Comment counts keyed by `ReviewFile.id`, so the list can show where
    /// feedback already exists without each row scanning every comment.
    var commentCounts: [String: Int] {
        comments.reduce(into: [:]) { counts, comment in
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
        let covered = lines.filter { ReviewSide.covers($0, on: side) }.sorted { $0.id < $1.id }
        let hunkIndex = covered.first?.hunkIndex
        let run = covered.filter { $0.hunkIndex == hunkIndex }
        // Nothing the reader can act on, so the composer closes: an empty run
        // or a diff that is gone is not a refusal they could answer.
        guard let diff, let first = run.first, let last = run.last else { return true }
        // By id against a set, not by value against the array. `contains` on
        // `[ReviewLine]` compares whole lines once per line of the run, and a
        // hundred thousand of each is ten billion comparisons — most of them
        // settled by the id, but the ones that are not read the whole line
        // comparisons on the main thread.
        let known = Set(diff.lines.lazy.map(\.id))
        guard run.allSatisfy({ known.contains($0.id) }) else { return true }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // One guard used to answer for all three, and a reader who hit the
        // comment limit was told their text held control characters. An empty
        // body returns without a message: the composer refuses to commit one,
        // so there is nothing for the reader to act on.
        guard !text.isEmpty else { return true }
        guard comments.count(where: { !$0.isResolved }) < Self.maxComments else {
            errorMessage = ReviewError.commentLimitReached.localizedDescription
            return false
        }
        guard text.utf8.count <= Self.maxCommentBytes else {
            errorMessage = ReviewError.commentTooLong.localizedDescription
            return false
        }
        do { try ReviewPromptBuilder.validate(text) } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let isRange = run.count > 1
        let excerpt = Self.excerpt(of: run)
        let comment = ReviewComment(
            file: diff.file,
            fingerprint: diff.fingerprint,
            // A run can start on an added line and end on a removed one, so
            // each side takes its own first and last numbered line.
            anchor: ReviewAnchor(
                lineID: first.id,
                oldLine: run.first { $0.oldLine != nil }?.oldLine,
                newLine: run.first { $0.newLine != nil }?.newLine
            ),
            end: isRange
                ? ReviewAnchor(
                    lineID: last.id,
                    oldLine: run.last { $0.oldLine != nil }?.oldLine,
                    newLine: run.last { $0.newLine != nil }?.newLine
                )
                : nil,
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

    /// The commented run as it goes into a draft: the text without its diff
    /// markers, which is what the surface draws, and the markers alongside,
    /// which is what the agent needs to tell an added line from a deleted one.
    ///
    /// Cut to `maxCodeExcerpt` UTF-8 bytes on a line boundary rather than mid
    /// line, so the two strings stay the same length in lines. A single line
    /// longer than the whole budget is the one exception and is cut where the
    /// budget ends: passing it through whole let a minified file produce a
    /// comment that could be written but never sent.
    private static func excerpt(of run: [ReviewLine]) -> (text: String, markers: String) {
        var lines: [String] = []
        var markers = ""
        var budget = maxCodeExcerpt
        for line in run {
            let isFirst = lines.isEmpty
            let cost = isFirst ? line.text.utf8.count : line.text.utf8.count + 1
            guard budget >= cost || isFirst else { break }
            var excerpt = ""
            if isFirst {
                var bytes = 0
                for scalar in line.text.unicodeScalars {
                    let size = scalar.utf8.count
                    guard bytes + size <= budget else { break }
                    excerpt.unicodeScalars.append(scalar)
                    bytes += size
                }
            }
            lines.append(isFirst ? excerpt : line.text)
            budget -= min(cost, budget)
            markers.append(line.kind.marker)
        }
        return (lines.joined(separator: "\n"), markers)
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
            errorMessage = ReviewError.commentTooLong.localizedDescription
            return false
        }
        do { try ReviewPromptBuilder.validate(text) } catch {
            errorMessage = error.localizedDescription
            return false
        }
        var next = comments
        guard let index = next.firstIndex(where: { $0.id == id }) else { return true }
        next[index].body = text
        return commit(next)
    }

    func remove(_ id: UUID) {
        commit(comments.filter { $0.id != id })
    }

    /// The comments that can be inserted now, with the rest recorded as stale.
    ///
    /// Named for what it produces rather than for the check it runs: it also
    /// writes `staleCommentIDs`, which is what raises the banner, so a name
    /// that read as a pure test would be a promise it does not keep.
    ///
    /// Per comment, not per review. Old line numbers must never silently
    /// target new code, but one comment whose file has moved on used to hold
    /// back every other comment in the review — and while an agent is working
    /// in the same worktree, that is most of the time. The stale ones stay in
    /// the draft, out of the prompt, for the reader to redo or delete.
    func insertable(_ expected: [ReviewComment]) async throws -> [ReviewComment] {
        // The review moved under the press. Nothing is stale; pressing Insert
        // again is the answer, which is a different sentence from the one a
        // stale comment needs.
        guard !expected.isEmpty, comments == expected else { throw ReviewError.checkInterrupted }
        let open = expected.filter { !$0.isResolved }
        guard !open.isEmpty else { throw ReviewError.nothingToInsert }
        guard base != nil || !open.contains(where: { $0.file.layer == .branch }) else {
            throw ReviewError.baseUnavailable
        }
        var latestFiles: Set<ReviewFile> = []
        for listed in scopes(for: open) {
            try await latestFiles.formUnion(git.files(at: root, scope: listed))
        }
        var fingerprints: [String: String] = [:]
        for file in Set(open.map(\.file)) where latestFiles.contains(file) {
            do {
                fingerprints[file.id] = try await git.diff(file, root: root, base: base).fingerprint
            } catch is CancellationError {
                throw CancellationError()
            } catch ReviewError.checkInterrupted {
                // `HEAD` moved under the read. That is about the worktree, not
                // about this file, and the caller's retry is the answer.
                throw ReviewError.checkInterrupted
            } catch ReviewError.timedOut, ReviewError.gitFailed {
                // Git did not answer. That says nothing about whether these
                // comments still describe the file, and it used to be recorded
                // as though it did: the fingerprint stayed unset, every comment
                // on the file was marked stale, the banner said they no longer
                // matched the diff, and `Resolve All` would then resolve
                // comments that nothing had invalidated. A failure to ask is
                // not an answer, so it is reported as itself and the reader
                // retries.
                throw ReviewError.gitFailed
            } catch {
                // A file that grew past the limit, turned binary, or that Git
                // answered about and we cannot review. Leaving its fingerprint
                // unset holds back the comments on that file alone — which is
                // what the rest of this function does with a file whose content
                // moved.
                continue
            }
        }
        // The reader can edit or delete while Git runs; what we checked then
        // no longer describes what would be inserted. Their own edit, not a
        // stale comment — retrying is all this needs.
        guard comments == expected else { throw ReviewError.checkInterrupted }
        let valid = open.filter { fingerprints[$0.file.id] == $0.fingerprint }
        // Only what we asked Git about is re-answered here. A resolved comment
        // keeps whatever `load` last decided about it, so reopening one does
        // not present it as current on the strength of a check we skipped.
        let checked = Set(open.map(\.id))
        staleCommentIDs = staleCommentIDs.subtracting(checked).union(checked.subtracting(valid.map(\.id)))
        guard !valid.isEmpty else { throw ReviewError.changed }
        return valid
    }

    /// The gaps in the open file, and what is still folded in each.
    var gaps: [ReviewGap] {
        guard let diff else { return [] }
        return ReviewExpansionPlan.gaps(in: diff.lines, sourceCount: source.isEmpty ? nil : source.count)
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

    /// Which file to open when the surface has none, or `nil` for the first
    /// changed file.
    ///
    /// Only ever a file the current list carries: the worktree moves between
    /// readings, and a remembered id can name a file that is committed, reset,
    /// or in the scope's other half by now.
    var resumeFileID: String? {
        guard let lastFileID, files.contains(where: { $0.id == lastFileID }) else { return nil }
        return lastFileID
    }

    /// Records where the reader is, so closing review and opening it again
    /// comes back here.
    ///
    /// Navigation is an optimistic hint. We coalesce it off the main actor;
    /// comment edits still wait for durable storage before closing the composer.
    func rememberOpenFile(_ fileID: String?) {
        guard let fileID, fileID != lastFileID else { return }
        lastFileID = fileID
        scheduleNavigationSave()
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
                fingerprint: diff?.file.id == fileID ? diff?.fingerprint : nil
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
            marks[file.id] = ReviewViewMark(added: mark.added, removed: mark.removed, fingerprint: fingerprint)
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
    /// Only within the scope being shown. The two scopes name their files with
    /// disjoint layers, so a scope-blind prune read "not in this list" as
    /// "gone" for every mark the other scope had made — and since the scope is
    /// not persisted, simply reopening review threw away everything read on the
    /// branch. Comments are already protected this way through `scopes(for:)`.
    private func pruneViewed() {
        let listed = Set(files.map(\.id))
        let mine = Set(scope.layers.map { $0.rawValue + ":" })
        let kept = viewed.filter { id, mark in
            guard mine.contains(where: { id.hasPrefix($0) }) else { return true }
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
    @discardableResult
    func markInserted(_ ids: [UUID], at date: Date = Date()) -> Bool {
        let sent = Set(ids)
        guard comments.contains(where: { sent.contains($0.id) }) else { return true }
        var next = comments
        for index in next.indices where sent.contains(next[index].id) {
            next[index].insertedAt = date
        }
        commit(next)
        return comments == next
    }

    /// Take the mark back off comments whose paste never landed.
    ///
    /// The paste action answers as soon as the request starts, and the
    /// confirmation sheet an unbracketed multi-line paste goes through answers
    /// much later. A refusal there means the terminal received nothing, so the
    /// mark that says otherwise has to come off: it is what the card and the
    /// preview show, and a reader who believes a comment reached an agent
    /// stops waiting for an answer to it. Nothing is held back from a later
    /// insert either way — being delivered is not being dealt with.
    func unmarkInserted(_ ids: [UUID]) {
        let sent = Set(ids)
        var next = comments
        var changed = false
        for index in next.indices where sent.contains(next[index].id) && next[index].insertedAt != nil {
            next[index].insertedAt = nil
            changed = true
        }
        guard changed else { return }
        guard commit(next) else {
            // The paste was refused, so these comments never reached an agent,
            // and the draft could not be told. `commit` leaves `comments`
            // alone on a failure, so both memory and disk still record them as
            // delivered — and this store is usually unreferenced by then (the
            // pool holds it weakly and review has closed), so the message it
            // set goes nowhere. Clearing the marks in memory is what the
            // reader can still be shown if they reopen review in this session;
            // the draft is corrected by the next successful write.
            comments = next
            log.error("could not record a refused paste for \(sent.count, privacy: .public) comments")
            return
        }
    }

    func setResolved(_ id: UUID, _ isResolved: Bool, at date: Date = Date()) {
        var next = comments
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        // Unresolving adds to the unresolved count, so it answers to the same
        // cap `add` does. Without this a draft could be written past the limit
        // that `init` refuses to load, which took the whole draft with it.
        if !isResolved, next[index].isResolved {
            guard next.count(where: { !$0.isResolved }) < Self.maxComments else {
                errorMessage = ReviewError.commentLimitReached.localizedDescription
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
        let ids = staleCommentIDs
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

    /// The scopes a set of comments was written against.
    ///
    /// Usually one — the reader has not switched views — but a comment kept
    /// from the other view still has to be checked against the list it came
    /// from. Looking only at the current one would report it as a file that no
    /// longer changes, which is the same silence as aging it out.
    private func scopes(for comments: [ReviewComment]) -> [ReviewScope] {
        var result: [ReviewScope] = []
        if comments.contains(where: { $0.file.layer != .branch }) {
            result.append(.uncommitted)
        }
        if let base, comments.contains(where: { $0.file.layer == .branch }) {
            result.append(.branch(base: base))
        }
        return result
    }

    /// Takes the banner down ahead of an operation the reader has just asked
    /// for, so what they read afterwards belongs to that operation.
    ///
    /// The quarantine notice survives: it is not about any one operation, and
    /// nothing but a readable draft answers it. Callers outside the store go
    /// through here rather than assigning, which is what let a refresh clear
    /// that notice and leave the reader with no sign that their comments were
    /// set aside.
    func clearError() {
        errorMessage = hasUnreadableDraft ? ReviewError.draftUnreadable.localizedDescription : nil
    }

    /// Puts a failure the surface handled — building the prompt, reaching the
    /// pane — where the same banner can carry it, since to the reader it is
    /// the review that did not work.
    func report(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    /// Clears the message an operation is entitled to clear, and puts back the
    /// one it is not.
    ///
    /// A failed change list and an unreadable draft are both messages no
    /// operation may clear: only another refresh, or a readable draft, answers
    /// them. This used to bail out on either, which is not the same thing as
    /// restoring them — an operation that failed in between had already
    /// overwritten the banner, so a later success left its own resolved error
    /// on screen and the standing message never came back.
    private func clearOperationError() {
        if let listRefreshMessage {
            errorMessage = listRefreshMessage
            return
        }
        errorMessage = hasUnreadableDraft ? ReviewError.draftUnreadable.localizedDescription : nil
    }

    private func updateNavigationMarks(_ marks: [String: ReviewViewMark]) {
        viewed = marks
        scheduleNavigationSave()
    }

    private func scheduleNavigationSave() {
        navigationSaveTask?.cancel()
        let token = UUID()
        navigationGeneration = token
        let writeGeneration = ReviewDraftWriteCoordinator.shared.beginNavigation(for: root)
        // We retain the store through this bounded save so closing review immediately
        // after selecting a file does not discard the pending navigation hint.
        navigationSaveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: PersistenceTiming.coalescing)
                try Task.checkCancellation()
                let snapshot = ReviewDraft(comments: comments, viewed: viewed, lastFileID: lastFileID)
                _ = try await Self.writeNavigation(
                    snapshot, root: root, storage: drafts, generation: writeGeneration
                )
            } catch is CancellationError {
                // A newer navigation or a synchronous edit owns persistence now.
            } catch {
                guard navigationGeneration == token, !Task.isCancelled else { return }
                errorMessage = (error as? ReviewError ?? .storageFailed).localizedDescription
            }
        }
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

    /// Whether the draft was written. The composer asks so it can stay open
    /// with the reader's text in it when it was not — closing on a failed save
    /// threw away what they had just written, with only a banner to say why.
    @discardableResult
    private func commit(_ next: [ReviewComment], viewed nextViewed: [String: ReviewViewMark]? = nil) -> Bool {
        navigationSaveTask?.cancel()
        navigationGeneration = UUID()
        let marks = nextViewed ?? viewed
        do {
            try ReviewDraftWriteCoordinator.shared.save(
                ReviewDraft(
                    comments: next,
                    viewed: marks.isEmpty ? nil : marks,
                    lastFileID: lastFileID
                ),
                root: root,
                storage: drafts
            )
            comments = next
            viewed = marks
            staleCommentIDs.formIntersection(Set(next.map(\.id)))
            clearOperationError()
            return true
        } catch let error as ReviewError {
            errorMessage = error.localizedDescription
            return false
        } catch {
            errorMessage = ReviewError.storageFailed.localizedDescription
            return false
        }
    }

}

/// Serialized with a lock rather than by isolating the type. The one method
/// hands back a `@MainActor` store and is only called from view code, but the
/// pool is an `@Entry` default value, which SwiftUI builds outside any actor —
/// so the type itself cannot be `@MainActor`.
final class ReviewStorePool: @unchecked Sendable {
    /// Where the stores this pool hands out keep their drafts. In demo mode
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

    private final class WeakStore {
        weak var value: ReviewStore?
        init(_ value: ReviewStore) {
            self.value = value
        }
    }

    /// Where drafts live. Named here rather than at each use so the deletion
    /// path and the pool cannot end up looking in two places.
    static var defaultDirectory: URL {
        LimpidPaths.applicationSupportDirectory().appendingPathComponent("reviews")
    }

    private let lock = NSLock()
    private var openStores: [String: WeakStore] = [:]

    @MainActor
    func store(root: URL) -> ReviewStore {
        if let existing = lock.withLock({
            openStores = openStores.filter { $0.value.value != nil }
            return openStores[root.path]?.value
        }) {
            return existing
        }
        let store = ReviewStore(root: root, drafts: drafts)
        lock.withLock { openStores[root.path] = WeakStore(store) }
        return store
    }

}
