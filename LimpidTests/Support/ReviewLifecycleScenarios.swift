// ReviewLifecycleScenarios.swift
// Limpid — how a review comment moves from written to sent to resolved.
//
// Its own file rather than more of `ReviewValidationScenarios`: the enum it
// extends had grown past what one type body should hold, and these scenarios
// share nothing with the parser and Git ones but their fixtures.

import Foundation
@testable import Limpid

extension ReviewValidationScenarios {
    /// The three states a comment moves through, and what each one changes.
    ///
    /// Delivery and resolution are separate on purpose: an agent that was
    /// handed five comments and fixed three leaves two that have to go again,
    /// so being sent must not withdraw a comment from the next prompt. Only
    /// the reader saying it is handled does that.
    @MainActor
    static func lifecycle(at directory: URL) async throws {
        let repository = directory.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await seed(repository)
        let root = try await ReviewGit.root(at: repository)
        try "one\ntwo\nthree\n".write(
            to: root.appendingPathComponent("new.txt"),
            atomically: true,
            encoding: .utf8
        )
        let storage = directory.appendingPathComponent("drafts")
        let store = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await store.refresh()
        await store.flushNavigationSave()
        guard let file = store.files.first else { throw ReviewValidationFailure(message: "File missing") }
        await store.load(file)
        await store.flushNavigationSave()
        let lines = store.diff?.lines.filter(\.isCommentable) ?? []
        try require(lines.count >= 2, "The seed needs two commentable lines")
        store.add(line: lines[0], body: "First.")
        store.add(line: lines[1], body: "Second.")
        try require(store.comments.count == 2, "Setup failed: \(store.errorMessage ?? "")")
        // A draft written before either timestamp existed reads as unsent and
        // unresolved, which is what an old draft on disk has to become.
        try require(
            store.comments.allSatisfy { $0.insertedAt == nil && !$0.isResolved },
            "A new comment did not start unsent and unresolved"
        )
        let sent = try await store.insertable(store.comments)
        try require(store.markInserted(sent.map(\.id)), "The delivery could not be recorded")
        let afterSending = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments
        try require(
            afterSending.count == 2 && afterSending.allSatisfy { $0.insertedAt != nil },
            "Delivery did not persist"
        )
        // Sent, and still asked for: the agent may have answered none of it.
        try await require(store.insertable(store.comments).count == 2, "A sent comment was held back")
        // A paste refused at the confirmation sheet delivered nothing, and the
        // mark comes back off. The refusal arrives long after the paste action
        // answered, so this runs against a store review has already left.
        store.unmarkInserted(sent.map(\.id))
        try require(
            store.comments.allSatisfy { $0.insertedAt == nil },
            "A refused paste left its comments recorded as delivered"
        )
        let unmarked = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).comments
        try require(
            unmarked.count == 2 && unmarked.allSatisfy { $0.insertedAt == nil },
            "Taking the mark back did not persist"
        )
        try require(store.markInserted(sent.map(\.id)), "The delivery could not be recorded again")
        let resolved = store.comments[0].id
        store.setResolved(resolved, true)
        let reloaded = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        try require(reloaded.comments.count == 2, "A draft carrying dates did not reload")
        try require(reloaded.comments.first?.isResolved == true, "Resolution did not persist")
        let remaining = try await store.insertable(store.comments)
        try require(remaining.count == 1 && remaining[0].id != resolved, "A resolved comment was sent")
        try require(
            ReviewPromptBuilder.build(root: root, comments: remaining).text.contains("Second."),
            "The prompt lost the comment that still stands"
        )
        store.setResolved(store.comments[1].id, true)
        do {
            _ = try await store.insertable(store.comments)
            throw ReviewValidationFailure(message: "A fully resolved review was sent")
        } catch ReviewError.nothingToInsert {}
        store.setResolved(resolved, false)
        try await require(store.insertable(store.comments).count == 1, "Unresolving did not restore the comment")
        // Bulk resolve takes the stale ones and nothing else, and the draft it
        // replaced comes back whole.
        try "changed\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await store.insertable(store.comments)
            throw ReviewValidationFailure(message: "A stale comment was sent")
        } catch ReviewError.changed {}
        try require(store.staleCommentIDs.count == 1, "Staleness not recorded")
        guard let previous = store.resolveStale() else {
            throw ReviewValidationFailure(message: "Bulk resolve did nothing")
        }
        try require(store.comments.allSatisfy(\.isResolved), "Bulk resolve left a stale comment open")
        store.restore(previous, from: store.comments)
        try require(store.comments == previous, "Undo did not restore the draft")
        try require(store.resolveStale() != nil, "Bulk resolve is not repeatable after undo")
        // Nothing left to resolve is not an action, so there is nothing to undo.
        try require(store.resolveStale() == nil, "Bulk resolve offered an undo for no change")
        // A stale comment was never sent, so it must not be recorded as having
        // been. `markInserted` is called with what went into the prompt, and this
        // is what stops a wider call from marking the rest.
        let untouched = store.comments.map(\.insertedAt)
        store.markInserted([UUID()])
        try require(store.comments.map(\.insertedAt) == untouched, "Delivery was recorded for a comment that was not sent")
        // Undo defers to a newer edit rather than overwriting it.
        store.restore([], from: [])
        try require(!store.comments.isEmpty, "Undo restored over a draft it was not written against")
        try await legacyDraft(at: directory)
    }

    /// What a read mark survives, and what takes it away.
    ///
    /// The mark is only worth having if it comes off by itself: one that
    /// stayed after the file changed would tell the reader they had read work
    /// they have not seen. Two signals do that — the change list's counts,
    /// which are refreshed anyway, and the fingerprint, which catches an edit
    /// the counts cannot see.
    @MainActor
    static func viewMarks(at directory: URL) async throws {
        let repository = directory.appendingPathComponent("viewed")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await seed(repository)
        let root = try await ReviewGit.root(at: repository)
        // Tracked, because Git reports no counts for an untracked file: there
        // the fingerprint is the only signal, which the open-file check below
        // exercises either way.
        let fileURL = root.appendingPathComponent("tracked.txt")
        try "one\ntwo\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await checkedGit(["add", "tracked.txt"], cwd: root)
        _ = try await checkedGit(
            ["-c", "user.email=review@example.com", "-c", "user.name=Review", "commit", "-qm", "seed"],
            cwd: root
        )
        try "one\nTWO\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
        let storage = directory.appendingPathComponent("viewed-drafts")
        let store = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await store.refresh()
        await store.flushNavigationSave()
        let file = try require(store.files.first, "File missing")
        await store.load(file)
        await store.flushNavigationSave()
        store.setViewed(file.id, true)
        try require(store.viewed[file.id]?.fingerprint != nil, "An open file was marked without its fingerprint")
        try require(
            ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage)).viewed[file.id] != nil,
            "The mark did not persist: \(store.errorMessage ?? "")"
        )
        // A refresh that finds the file unchanged leaves the mark alone.
        await store.refresh()
        await store.flushNavigationSave()
        try require(store.viewed[file.id] != nil, "An unchanged file lost its mark")
        // One line swapped for another: the counts are the same, so only
        // opening the file can tell that the reader has not seen this.
        try "one\nTHREE\nthree\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await store.refresh()
        await store.flushNavigationSave()
        try require(store.viewed[file.id] != nil, "A change the counts cannot see moved them")
        await store.load(file)
        await store.flushNavigationSave()
        try require(store.viewed[file.id] == nil, "An edited file kept its mark")
        // A line added moves the counts, which is what a mark made from the
        // list — with no fingerprint behind it — has to rely on.
        store.setViewed(file.id, true)
        try require(store.viewed[file.id] != nil, "The file could not be marked again")
        try "one\nTHREE\nthree\nfour\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await store.refresh()
        await store.flushNavigationSave()
        try require(store.viewed[file.id] == nil, "A file that grew kept its mark")
        // A mark made from the list has no fingerprint behind it: nothing has
        // been read to produce one. Opening the file is the first chance to
        // record it, and without that the mark would never be checked against
        // anything at all.
        let listed = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await listed.refresh()
        listed.setViewed(file.id, true)
        try require(listed.viewed[file.id]?.fingerprint == nil, "A mark made from the list carries no fingerprint")
        await listed.load(file)
        let adopted = try require(listed.viewed[file.id]?.fingerprint, "Opening the file did not record a fingerprint")
        try require(adopted == listed.diff?.fingerprint, "The recorded fingerprint is not the one on screen")
        listed.setViewed(file.id, false)
        await store.refresh()
        await store.flushNavigationSave()
        // A file put back the way it was leaves the change list, and a mark on
        // work that is no longer there is a mark on nothing.
        store.setViewed(file.id, true)
        _ = try await checkedGit(["checkout", "--", "tracked.txt"], cwd: root)
        await store.refresh()
        await store.flushNavigationSave()
        try require(store.viewed.isEmpty, "A file that left the list kept its mark")
    }

    /// A draft written before comments carried dates, read by the app that
    /// added them.
    ///
    /// The claim that an old draft still opens rests on synthesized `Codable`
    /// treating a missing key as `nil`, and on the decoder matching the
    /// encoder — which it did not, until a date first went through it. Both
    /// are worth a test that reads the old shape rather than a new one.
    @MainActor
    private static func legacyDraft(at directory: URL) async throws {
        let repository = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await seed(repository)
        let root = try await ReviewGit.root(at: repository)
        try "one\ntwo\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        let storage = directory.appendingPathComponent("legacy-drafts")
        let store = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        await store.refresh()
        await store.flushNavigationSave()
        guard let file = store.files.first else { throw ReviewValidationFailure(message: "File missing") }
        await store.load(file)
        await store.flushNavigationSave()
        guard let line = store.diff?.lines.first else { throw ReviewValidationFailure(message: "Line missing") }
        store.add(line: line, body: "Written before the dates existed.")
        store.markInserted(store.comments.map(\.id))
        try require(store.comments.count == 1, "Setup failed: \(store.errorMessage ?? "")")
        let saved = try require(
            FileManager.default.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil).first,
            "Saved draft missing"
        )
        // The keys an old app never wrote, taken back out of the file.
        var draft = try require(
            JSONSerialization.jsonObject(with: Data(contentsOf: saved)) as? [String: Any],
            "Draft is not an object"
        )
        var comments = try require(draft["comments"] as? [[String: Any]], "Draft has no comments")
        try require(comments[0].removeValue(forKey: "insertedAt") != nil, "The draft never carried a date")
        comments[0].removeValue(forKey: "resolvedAt")
        draft["comments"] = comments
        try JSONSerialization.data(withJSONObject: draft).write(to: saved)
        let reopened = ReviewStore(root: root, drafts: FileReviewDraftStore(directory: storage))
        try require(reopened.comments.count == 1, "An old draft did not reload: \(reopened.errorMessage ?? "")")
        try require(
            reopened.comments[0].insertedAt == nil && !reopened.comments[0].isResolved,
            "An old comment did not read as unsent and unresolved"
        )
    }
}
