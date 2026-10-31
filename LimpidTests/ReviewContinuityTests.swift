// ReviewContinuityTests.swift
// Limpid — where the reader was survives closing review and opening it again: the file that was open, saved with the
// comments and never over an edit.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct ReviewContinuityTests {
    /// Reopening review returns to the file that was being read, read from
    /// the list the new session is given. The remembered id is a hint: it
    /// only answers while the list still carries the file.
    @Test func reopeningTheReview_resumesTheFileThatWasOpen_untilItLeavesTheList() async {
        let root = URL(fileURLWithPath: "/tmp/limpid-review-resume")
        let drafts = RecordingReviewDraftStore()
        let repository = FakeReviewRepository()
        let first = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let second = ReviewFile(path: "b.swift", layer: .unstaged, status: .modified)
        repository.files = [first, second]
        repository.diffs = [
            first.id: ReviewDiff(file: first, fingerprint: "a", lines: []),
            second.id: ReviewDiff(file: second, fingerprint: "b", lines: [])
        ]

        let store = ReviewSession(root: root, git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        // Nothing has been read yet, so there is nothing to resume to.
        #expect(store.resumeFileID == nil)
        store.rememberOpenFile(second.id)
        await store.flushNavigationSave()
        #expect(store.errorMessage == nil)

        let reopened = ReviewSession(root: root, git: repository, drafts: drafts)
        #expect(await reopened.refreshAsTheAppDoes() == .applied(selectedFileID: second.id))
        #expect(reopened.resumeFileID == second.id)
        #expect(reopened.diff?.file == second)

        // The worktree moves between readings. A remembered file that is no
        // longer changed hands the choice back to the first one.
        repository.files = [first]
        let moved = ReviewSession(root: root, git: repository, drafts: drafts)
        await moved.refreshAsTheAppDoes()
        #expect(moved.lastFileID == second.id)
        #expect(moved.resumeFileID == nil)
    }

    @Test func aCommentAndTheFileOpenWhenItWasWritten_areSavedTogether() async throws {
        let repository = try FakeReviewRepository.oneFile()
        let file = FakeReviewRepository.unstagedFile
        let drafts = RecordingReviewDraftStore()
        let store = ReviewSession(root: URL(fileURLWithPath: "/tmp/limpid-review-root"), git: repository, drafts: drafts)
        await store.refreshAsTheAppDoes()
        await store.load(file)
        store.rememberOpenFile(file.id)
        let line = try #require(store.diff?.lines.first { $0.isCommentable })
        #expect(store.add(line: line, body: "Keep this comment."))
        await store.flushNavigationSave()
        let draft = try drafts.load(root: store.root)
        let saved = try #require(draft)
        #expect(saved.comments.count == 1)
        #expect(saved.lastFileID["uncommitted"] == file.id)
    }

    @Test func navigationQueuedAfterAnEditCannotOverwriteIt() async throws {
        let root = URL(fileURLWithPath: "/tmp/review-write-order")
        let drafts = RecordingReviewDraftStore()
        let writer = ReviewDraftWriteCoordinator.shared
        let generation = writer.beginNavigation(for: root)
        let committed = ReviewDraft(lastFileID: ["uncommitted": "newer"])
        try writer.save(committed, root: root, storage: drafts)
        let saved = try await writer.saveNavigation(
            ReviewDraft(lastFileID: ["uncommitted": "older"]),
            root: root,
            storage: drafts,
            generation: generation
        )
        #expect(!saved)
        let restored = try drafts.load(root: root)
        #expect(restored?.lastFileID["uncommitted"] == "newer")
    }

    @Test func deletingADraftCancelsDelayedNavigation() async throws {
        let repository = try FakeReviewRepository.oneFile()
        try await withTempDir { @Sendable directory in
            let store = await ReviewSession(root: directory, git: repository, drafts: FileReviewDraftStore(directory: directory))
            let draft = FileReviewDraftStore.url(root: directory, directory: directory)
            // Left alone, the delayed save writes the draft.
            await store.rememberOpenFile(FakeReviewRepository.unstagedFile.id)
            await store.flushNavigationSave()
            #expect(FileManager.default.fileExists(atPath: draft.path))

            await store.rememberOpenFile("another file")
            ReviewDraftWriter.removeDraft(root: directory, directory: directory)
            await store.flushNavigationSave()
            #expect(!FileManager.default.fileExists(atPath: draft.path))
        }
    }
}
