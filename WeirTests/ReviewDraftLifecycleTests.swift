// ReviewDraftLifecycleTests.swift
// Weir — how a review draft persists, and how a comment moves from written to sent to resolved.

import Foundation
import Testing
@testable import Weir

@MainActor
struct ReviewDraftLifecycleTests {
    /// The three states a comment moves through, and what each one changes.
    ///
    /// Delivery and resolution are separate on purpose: an agent that was
    /// handed five comments and fixed three leaves two that have to go again,
    /// so being sent must not withdraw a comment from the next prompt. Only
    /// the reader saying it is handled does that.
    @Test func sendingAndResolvingAreSeparateStates() async throws {
        try await withTempDir { directory in
            let repository = directory.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await TempGitRepo.initialize(repository)
            let root = try await ReviewGit.root(at: repository)
            try "one\ntwo\nthree\n".write(
                to: root.appendingPathComponent("new.txt"),
                atomically: true,
                encoding: .utf8
            )
            let storage = directory.appendingPathComponent("drafts")
            let store = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            let file = try #require(store.files.first, "File missing")
            await store.load(file)
            await store.flushNavigationSave()
            let lines = store.diff?.lines.filter(\.isCommentable) ?? []
            try #require(lines.count >= 2, "The seed needs two commentable lines")
            store.add(line: lines[0], body: "First.")
            store.add(line: lines[1], body: "Second.")
            try #require(
                store.comments.count == 2,
                "Setup failed: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            // A draft written before either timestamp existed reads as unsent and
            // unresolved, which is what an old draft on disk has to become.
            #expect(
                store.comments.allSatisfy { $0.insertedAt == nil && !$0.isResolved },
                "A new comment did not start unsent and unresolved"
            )
            let sent = try await store.insertable(store.comments)
            #expect(store.markInserted(sent).wasRecorded, "The delivery could not be recorded")
            let afterSending = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).comments
            #expect(
                afterSending.count == 2 && afterSending.allSatisfy { $0.insertedAt != nil },
                "Delivery did not persist"
            )
            // Sent, and still asked for: the agent may have answered none of it.
            #expect(try await store.insertable(store.comments).count == 2, "A sent comment was held back")
            let resolved = store.comments[0].id
            store.setResolved(resolved, true)
            let reloaded = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            #expect(reloaded.comments.count == 2, "A draft carrying dates did not reload")
            #expect(reloaded.comments.first?.isResolved == true, "Resolution did not persist")
            let remaining = try await store.insertable(store.comments)
            #expect(remaining.count == 1 && remaining[0].id != resolved, "A resolved comment was sent")
            #expect(
                try ReviewPromptBuilder.build(root: root, comments: remaining, locale: Locale(identifier: "en")).text.contains("Second."),
                "The prompt lost the comment that still stands"
            )
            store.setResolved(store.comments[1].id, true)
            await #expect(throws: ReviewError.nothingToInsert, "A fully resolved review was sent") {
                try await store.insertable(store.comments)
            }
            store.setResolved(resolved, false)
            #expect(try await store.insertable(store.comments).count == 1, "Unresolving did not restore the comment")
            // Bulk resolve takes the stale ones and nothing else, and the draft it
            // replaced comes back whole.
            try "changed\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            await #expect(throws: ReviewError.changed, "A stale comment was sent") { try await store.insertable(store.comments) }
            #expect(store.staleCommentIDs.count == 1, "Staleness not recorded")
            let previous = try #require(store.resolveStale(), "Bulk resolve did nothing")
            let isAllResolved = store.comments.allSatisfy(\.isResolved)
            #expect(isAllResolved, "Bulk resolve left a stale comment open")
            store.restore(previous, from: store.comments)
            #expect(store.comments == previous, "Undo did not restore the draft")
            #expect(store.resolveStale() != nil, "Bulk resolve is not repeatable after undo")
            // Nothing left to resolve is not an action, so there is nothing to undo.
            #expect(store.resolveStale() == nil, "Bulk resolve offered an undo for no change")
            // A stale comment was never sent, so it must not be recorded as having
            // been. `markInserted` is called with what went into the prompt, and this
            // is what stops a wider call from marking the rest.
            let untouched = store.comments.map(\.insertedAt)
            var stranger = try #require(store.comments.first, "Comment missing")
            stranger.id = UUID()
            store.markInserted([stranger])
            #expect(store.comments.map(\.insertedAt) == untouched, "Delivery was recorded for a comment that was not sent")
            // Undo defers to a newer edit rather than overwriting it.
            store.restore([], from: [])
            #expect(!store.comments.isEmpty, "Undo restored over a draft it was not written against")
        }
    }

    /// A draft written before comments carried dates, read by the app that
    /// added them.
    ///
    /// The claim that an old draft still opens rests on synthesized `Codable`
    /// treating a missing key as `nil`, and on the decoder matching the
    /// encoder — which it did not, until a date first went through it. Both
    /// are worth a test that reads the old shape rather than a new one.
    @Test func aDraftFromBeforeTheDatesStillOpens() async throws {
        try await withTempDir { directory in
            let repository = directory.appendingPathComponent("legacy")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await TempGitRepo.initialize(repository)
            let root = try await ReviewGit.root(at: repository)
            try "one\ntwo\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
            let storage = directory.appendingPathComponent("legacy-drafts")
            let store = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            let file = try #require(store.files.first, "File missing")
            await store.load(file)
            await store.flushNavigationSave()
            let line = try #require(store.diff?.lines.first, "Line missing")
            store.add(line: line, body: "Written before the dates existed.")
            store.markInserted(store.comments)
            try #require(
                store.comments.count == 1,
                "Setup failed: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            let saved = try #require(
                FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil).first,
                "Saved draft missing"
            )
            // The keys an old app never wrote, taken back out of the file.
            var draft = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any],
                "Draft is not an object"
            )
            var comments = try #require(draft["comments"] as? [[String: Any]], "Draft has no comments")
            let removedDate = comments[0].removeValue(forKey: "insertedAt")
            #expect(removedDate != nil, "The draft never carried a date")
            comments[0].removeValue(forKey: "resolvedAt")
            draft["comments"] = comments
            try JSONSerialization.data(withJSONObject: draft).write(to: saved)
            let reopened = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            try #require(
                reopened.comments.count == 1,
                "An old draft did not reload: \(reopened.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            #expect(
                reopened.comments[0].insertedAt == nil && !reopened.comments[0].isResolved,
                "An old comment did not read as unsent and unresolved"
            )
        }
    }

    /// What a read mark survives, and what takes it away.
    ///
    /// The mark is only worth having if it comes off by itself: one that
    /// stayed after the file changed would tell the reader they had read work
    /// they have not seen. Two signals do that — the change list's counts,
    /// which are refreshed anyway, and the fingerprint, which catches an edit
    /// the counts cannot see.
    @Test func aReadMarkComesOffWhenTheFileChanges() async throws {
        try await withTempDir { directory in
            let repository = directory.appendingPathComponent("viewed")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await TempGitRepo.initialize(repository)
            let root = try await ReviewGit.root(at: repository)
            // Tracked, because Git reports no counts for an untracked file: there
            // the fingerprint is the only signal, which the open-file check below
            // exercises either way.
            let fileURL = root.appendingPathComponent("tracked.txt")
            try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(
                ["-c", "user.email=review@example.com", "-c", "user.name=Review", "commit", "-qm", "seed"],
                cwd: root
            )
            try "one\nTWO\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
            let storage = directory.appendingPathComponent("viewed-drafts")
            let store = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            let file = try #require(store.files.first, "File missing")
            await store.load(file)
            await store.flushNavigationSave()
            store.setViewed(file.id, true)
            #expect(store.viewed[file.id]?.fingerprint != nil, "An open file was marked without its fingerprint")
            #expect(
                ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).viewed[file.id] != nil,
                "The mark did not persist: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            // A refresh that finds the file unchanged leaves the mark alone.
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            #expect(store.viewed[file.id] != nil, "An unchanged file lost its mark")
            // One line swapped for another: the counts are the same, so only
            // reading the file can tell that the reader has not seen this, and
            // Refresh reads the open file again.
            try "one\nTHREE\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            #expect(store.viewed[file.id] == nil, "An edited file kept its mark")
            // A line added moves the counts, which is what a mark made from the
            // list — with no fingerprint behind it — has to rely on.
            store.setViewed(file.id, true)
            #expect(store.viewed[file.id] != nil, "The file could not be marked again")
            try "one\nTHREE\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            #expect(store.viewed[file.id] == nil, "A file that grew kept its mark")
            // A mark made from the list has no fingerprint behind it: nothing has
            // been read to produce one. Opening the file is the first chance to
            // record it, and without that the mark would never be checked against
            // anything at all. Another changed file comes first in the list, so a
            // session of its own opens that one and the mark is made on a file
            // that is not open.
            let other = root.appendingPathComponent("a-other.txt")
            try "a\n".write(to: other, atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "a-other.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(
                ["-c", "user.email=review@example.com", "-c", "user.name=Review", "commit", "-qm", "other"],
                cwd: root
            )
            try "b\n".write(to: other, atomically: true, encoding: .utf8)
            let listed = ReviewSession(
                root: root,
                drafts: FileReviewDraftStore(directory: directory.appendingPathComponent("listed-drafts"))
            )
            await listed.refreshAsTheAppDoes()
            #expect(listed.diff?.file.id != file.id, "The list opened the file it was about to mark")
            listed.setViewed(file.id, true)
            #expect(listed.viewed[file.id]?.fingerprint == nil, "A mark made from the list carries no fingerprint")
            await listed.load(file)
            let adopted = try #require(listed.viewed[file.id]?.fingerprint, "Opening the file did not record a fingerprint")
            #expect(adopted == listed.diff?.fingerprint, "The recorded fingerprint is not the one on screen")
            listed.setViewed(file.id, false)
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            // A file put back the way it was leaves the change list, and a mark on
            // work that is no longer there is a mark on nothing.
            store.setViewed(file.id, true)
            _ = try await ReviewGitFixture.checked(["checkout", "--", "tracked.txt"], cwd: root)
            await store.refreshAsTheAppDoes()
            await store.flushNavigationSave()
            #expect(store.viewed.isEmpty, "A file that left the list kept its mark")
        }
    }

    @Test func draftsSurviveRestartAndRejectStaleSnapshots() async throws {
        try await withTempDir { directory in
            let repository = directory.appendingPathComponent("repo")
            try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
            try await TempGitRepo.initialize(repository)
            let root = try await ReviewGit.root(at: repository)
            let fileURL = root.appendingPathComponent("new.txt")
            try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
            let storage = directory.appendingPathComponent("drafts")
            let store = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            await store.refreshAsTheAppDoes()
            let file = try #require(store.files.first, "File missing")
            await store.load(file)
            let line = try #require(store.diff?.lines.first, "Line missing")
            store.add(line: line, body: "Add a test.")
            try #require(
                store.comments.count == 1,
                "First save failed: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            // A comment over a run keeps both ends through a round-trip.
            let run = store.diff?.lines.filter(\.isCommentable) ?? []
            try #require(run.count > 1, "The fixture needs a run of at least two commentable lines")
            store.add(lines: Array(run.prefix(2)), side: nil, body: "Covers a run.")
            let ranged = try #require(store.comments.last, "Range comment missing")
            #expect(ranged.end?.lineID == run[1].id, "Range end not recorded")
            #expect(
                ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.last?.end?.lineID == run[1].id,
                "Range did not round-trip"
            )
            store.remove(ranged.id)
            // A run selected in one column of the split layout covers the whole id
            // range, and only the lines that column draws belong to the comment.
            // That needs a replacement to filter: the untracked file above is all
            // additions.
            let tracked = root.appendingPathComponent("tracked.txt")
            try "alpha\nbeta\n".write(to: tracked, atomically: true, encoding: .utf8)
            _ = try await ReviewGitFixture.checked(["add", "tracked.txt"], cwd: root)
            _ = try await ReviewGitFixture.checked(
                ["-c", "user.email=review@example.com", "-c", "user.name=Review", "commit", "-qm", "seed"],
                cwd: root
            )
            try "gamma\ndelta\n".write(to: tracked, atomically: true, encoding: .utf8)
            await store.refreshAsTheAppDoes()
            let replaced = try #require(store.files.first(where: { $0.path == "tracked.txt" }), "The replacement is not in the change list")
            await store.load(replaced)
            let replacement = store.diff?.lines.filter(\.isCommentable) ?? []
            #expect(replacement.contains { $0.newLine == nil }, "The replacement has no old-only line")
            #expect(replacement.contains { $0.oldLine == nil }, "The replacement has no new-only line")
            store.add(lines: replacement, side: .new, body: "Quote the new side only.")
            let sided = try #require(
                store.comments.last,
                "Side comment missing: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            try #require(
                sided.side == .new,
                "Side comment missing: \(store.errorMessage.map { $0.resolved(in: Locale(identifier: "en")) } ?? "")"
            )
            let quoted = Set(sided.code.split(separator: "\n").map(String.init))
            #expect(
                replacement.filter { $0.newLine == nil }.allSatisfy { !quoted.contains($0.text) },
                "A new-side comment quoted a line only the old column draws"
            )
            #expect(
                sided.anchor.newLine != nil && sided.anchor.oldLine == nil,
                "A new-side comment took an old-side position"
            )
            #expect(
                ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.last?.side == .new,
                "The column did not round-trip"
            )
            store.remove(sided.id)
            let restored = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            #expect(restored.comments == store.comments, "Draft did not round-trip")
            #expect(
                try await store.insertable(store.comments).count == store.comments.count,
                "A comment matching the worktree was held back"
            )
            try "modified\n".write(to: fileURL, atomically: true, encoding: .utf8)
            await #expect(throws: ReviewError.changed, "Stale comment accepted") { try await store.insertable(store.comments) }
            #expect(store.staleCommentIDs.count == 1, "Stale comment not marked")
            let id = try #require(store.comments.first?.id, "The comment under edit is gone")
            store.edit(id, body: "Edited.")
            #expect(store.staleCommentIDs.count == 1, "Editing must not re-anchor a stale comment")
            store.remove(id)
            #expect(ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.isEmpty, "Deletion not persisted")
            let files = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            let saved = try #require(files.first, "Saved file missing")
            let attributes = try FileManager.default.attributesOfItem(atPath: saved.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Draft permissions")
            try Data("corrupt".utf8).write(to: saved)
            let broken = ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage))
            await broken.refreshAsTheAppDoes()
            await broken.load(file)
            let recovered = try #require(broken.diff?.lines.first, "The reopened store has no diff to comment on")
            broken.add(line: recovered, body: "Written after an unreadable draft.")
            // The reader's bytes survive beside a fresh draft, and review keeps
            // working. Refusing to save was meant to protect a draft we could not
            // read, but nothing ever turned saving back on: one unreadable file
            // locked that repository out of review for good, and the only way back
            // was to find the file and delete it.
            let after = try FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil)
            let quarantined = try #require(
                after.first { $0.lastPathComponent.contains(".bak-decode-failed-") },
                "Unreadable draft was not kept"
            )
            #expect(try Data(contentsOf: quarantined) == Data("corrupt".utf8), "Unreadable draft was not kept verbatim")
            #expect(broken.comments.count == 1, "A comment written after an unreadable draft was refused")
            #expect(
                ReviewSession(root: root, drafts: FileReviewDraftStore(directory: storage)).comments.count == 1,
                "The draft written after an unreadable one did not persist"
            )
        }
    }
}
