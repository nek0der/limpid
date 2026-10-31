// ReviewDraftMigrationTests.swift
// Weir — the review draft on disk: the names it is read by, a version 1 draft brought forward to scopes with a copy
// of the original kept, what it refuses, and how much it holds.

import CryptoKit
import Foundation
import Testing
@testable import Weir
@testable import WeirDomain

@Suite("Review draft migration", .tags(.persistence))
struct ReviewDraftMigrationTests {
    private static let root = URL(fileURLWithPath: "/tmp/weir-review-migration")

    /// A version 1 comment on `layer`, as that version wrote it.
    private static func comment(_ id: String, layer: String, body: String = "Why?") -> String {
        """
        {"id":"\(id)","file":{"path":"a.swift","layer":"\(layer)","status":"M"},
         "fingerprint":"f1","anchor":{"lineID":1,"newLine":1},"code":"x","body":"\(body)"}
        """
    }

    private static func write(_ json: String, in directory: URL) throws -> URL {
        let file = FileReviewDraftStore.url(root: root, directory: directory)
        try Data(json.utf8).write(to: file)
        return file
    }

    @Test func workingCopyComments_keepTheirScope_withTheirMarksAndOpenFile() throws {
        try withTempDir { directory in
            let json = """
            {"version":1,
             "comments":[\(Self.comment("8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21", layer: "unstaged")),
                         \(Self.comment("8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A22", layer: "untracked"))],
             "viewed":{"unstaged:a.swift":{"added":1,"removed":0},"turn:a.swift":{"added":2,"removed":0}},
             "lastFileID":"staged:b.swift"}
            """
            _ = try Self.write(json, in: directory)

            let draft = try #require(try FileReviewDraftStore(directory: directory).load(root: Self.root))

            #expect(draft.version == 2)
            #expect(draft.comments.map(\.scopeIDs) == [["uncommitted"], ["uncommitted"]])
            #expect(draft.legacy == nil)
            #expect(draft.viewed == ["uncommitted": ["unstaged:a.swift": ReviewViewMark(added: 1, removed: 0)]])
            #expect(draft.lastFileID == ["uncommitted": "staged:b.swift"])
        }
    }

    @Test func aTurnsComment_isAlwaysLegacy() throws {
        // Version 1 recorded neither the snapshot nor the conversation, so no
        // record can prove which turn it was about.
        try withTempDir { directory in
            let json = """
            {"version":1,"comments":[\(Self.comment("8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21", layer: "turn"))],
             "lastFileID":"turn:a.swift"}
            """
            _ = try Self.write(json, in: directory)

            let draft = try #require(try FileReviewDraftStore(directory: directory).load(root: Self.root))

            #expect(draft.comments.isEmpty)
            #expect(draft.legacy?.map(\.body) == ["Why?"])
            #expect(draft.legacy?.allSatisfy(\.scopeIDs.isEmpty) == true)
            #expect(draft.lastFileID.isEmpty)
        }
    }

    @Test func aBranchComment_isLegacy_sinceVersion1KeptNoBase() throws {
        try withTempDir { directory in
            let json = """
            {"version":1,"comments":[\(Self.comment("8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21", layer: "branch"))]}
            """
            _ = try Self.write(json, in: directory)

            let draft = try #require(try FileReviewDraftStore(directory: directory).load(root: Self.root))

            #expect(draft.comments.isEmpty)
            #expect(draft.legacy?.count == 1)
        }
    }

    /// A version 2 draft an earlier build saved from the per-pane "This turn"
    /// scope, which no build offers now: the whole file still reads, the turn
    /// comment comes back legacy (read only until moved), and the rest keeps
    /// its scope. The format is unchanged, so nothing is migrated.
    @MainActor
    @Test func aVersion2ThisTurnComment_stillDecodes_asLegacy() throws {
        try withTempDir { directory in
            let turnComment = """
            {"id":"8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21","scopeIDs":["turn:abc"],
             "file":{"path":"a.swift","layer":"turn","status":"M"},
             "fingerprint":"f1","anchor":{"lineID":1,"newLine":1},"code":"x","body":"About this turn"}
            """
            let workingComment = """
            {"id":"8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A22","scopeIDs":["uncommitted"],
             "file":{"path":"a.swift","layer":"unstaged","status":"M"},
             "fingerprint":"f1","anchor":{"lineID":1,"newLine":1},"code":"x","body":"About the worktree"}
            """
            let json = """
            {"version":2,"comments":[\(turnComment),\(workingComment)],
             "viewed":{"turn:abc":{"turn:a.swift":{"added":1,"removed":0}},
                       "uncommitted":{"unstaged:a.swift":{"added":1,"removed":0}}},
             "lastFileID":{"turn:abc":"turn:a.swift","uncommitted":"unstaged:a.swift"}}
            """
            // A root of its own: the review's writers are shared by root.
            let reviewRoot = URL(fileURLWithPath: "/tmp/weir-review-this-turn-\(UUID().uuidString)")
            let file = FileReviewDraftStore.url(root: reviewRoot, directory: directory)
            try Data(json.utf8).write(to: file)
            let store = FileReviewDraftStore(directory: directory)

            let draft = try #require(try store.load(root: reviewRoot))

            #expect(draft.version == 2)
            #expect(MigrationBackup.readLedger(for: file) == nil, "nothing to migrate")
            let turn = try #require(draft.comments.first { $0.body == "About this turn" })
            #expect(turn.file.layer == .turn)
            #expect(turn.isLegacy)
            #expect(draft.comments.first { $0.body == "About the worktree" }?.isLegacy == false)
            #expect(draft.viewed["uncommitted"] == ["unstaged:a.swift": ReviewViewMark(added: 1, removed: 0)])

            let session = ReviewSession(root: reviewRoot, git: FakeReviewRepository(), drafts: store)
            #expect(session.legacyComments.map(\.body) == ["About this turn"])
            #expect(session.comments(inScope: ReviewScope.uncommitted.scopeID).map(\.body) == ["About the worktree"])
            #expect(!session.isCheckedHere(turn), "no scope has that turn's snapshot")
        }
    }

    @Test func theOriginal_isKeptBeside_andTheMigratedDraftIsWrittenOnce() throws {
        try withTempDir { directory in
            let original = """
            {"version":1,"comments":[\(Self.comment("8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21", layer: "staged"))]}
            """
            let file = try Self.write(original, in: directory)
            let store = FileReviewDraftStore(directory: directory)

            _ = try store.load(root: Self.root)

            let record = try #require(MigrationBackup.readLedger(for: file))
            #expect(record.fromVersion == 1)
            #expect(record.toVersion == 2)
            let copy = directory.appendingPathComponent(record.backupFileName)
            #expect(try Data(contentsOf: copy) == Data(original.utf8))
            #expect(Self.version(of: file) == 2)
            // The second launch reads version 2 and takes no second copy.
            _ = try store.load(root: Self.root)
            #expect(MigrationBackup.readLedger(for: file) == record)
        }
    }

    @Test func theLedger_recordsTheWrite() throws {
        try withTempDir { directory in
            let file = try Self.write(#"{"version":1,"comments":[]}"#, in: directory)

            _ = try FileReviewDraftStore(directory: directory).load(root: Self.root)

            #expect(MigrationBackup.readLedger(for: file)?.stage == .written)
        }
    }

    /// Version 1 wrote no key for marks or an open file it did not have,
    /// and read `null` for either as absent; both still migrate.
    @Test func aVersion1DraftWithNullMarksAndOpenFile_migrates() throws {
        try withTempDir { directory in
            let file = try Self.write(#"{"version":1,"comments":[],"viewed":null,"lastFileID":null}"#, in: directory)

            let draft = try #require(try FileReviewDraftStore(directory: directory).load(root: Self.root))

            #expect(draft.viewed.isEmpty)
            #expect(draft.lastFileID.isEmpty)
            #expect(Self.version(of: file) == 2)
        }
    }

    /// The ledger as a launch left it when it ended after writing the
    /// migrated draft but before recording that.
    private static func rewindLedger(for file: URL) throws {
        var record = try #require(MigrationBackup.readLedger(for: file))
        record.stage = .backedUp
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(record).write(to: MigrationBackup.ledgerURL(for: file))
    }

    @Test func aLaunchThatEndedBeforeTheLedger_isFinishedByTheNextRead() throws {
        try withTempDir { directory in
            let file = try Self.write(#"{"version":1,"comments":[]}"#, in: directory)
            let store = FileReviewDraftStore(directory: directory)
            _ = try store.load(root: Self.root)
            try Self.rewindLedger(for: file)

            _ = try store.load(root: Self.root)

            #expect(MigrationBackup.readLedger(for: file)?.stage == .written)
        }
    }

    /// The migration's own write failed, so the original is still on disk;
    /// the first save of the migrated draft finishes the ledger with the
    /// bytes it wrote, which the next read then matches.
    @Test func aFailedMigrationWrite_isFinishedByTheFirstSave() throws {
        try withTempDir { directory in
            let original = #"{"version":1,"comments":[]}"#
            let file = try Self.write(original, in: directory)
            let store = FileReviewDraftStore(directory: directory)
            var draft = try #require(try store.load(root: Self.root))
            try Data(original.utf8).write(to: file)
            try Self.rewindLedger(for: file)
            let migrated = try #require(MigrationBackup.readLedger(for: file))
            // Changed before the save, so its bytes differ from the
            // migration's own and the ledger must take them from the save.
            draft.lastFileID = ["uncommitted": "unstaged:a.swift"]

            try store.save(draft, root: Self.root)

            let record = try #require(MigrationBackup.readLedger(for: file))
            #expect(record.stage == .written)
            #expect(record.migratedSHA256 != migrated.migratedSHA256)
            let saved = try Data(contentsOf: file)
            #expect(record.migratedSHA256 == SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined())
            _ = try store.load(root: Self.root)
            #expect(MigrationBackup.readLedger(for: file) == record)
        }
    }

    /// A ledger left at `backedUp` by an earlier launch is not finished by
    /// a save that only starts afresh after the draft was set aside: the
    /// file it writes is not the migrated draft.
    @Test func aSaveAfterTheDraftWasSetAside_leavesAnUnfinishedLedger() throws {
        try withTempDir { directory in
            let file = try Self.write(#"{"version":1,"comments":[]}"#, in: directory)
            let store = FileReviewDraftStore(directory: directory)
            _ = try store.load(root: Self.root)
            try Self.rewindLedger(for: file)
            try Data(#"{"version":3,"comments":[]}"#.utf8).write(to: file)
            #expect(throws: ReviewError.self) { try store.load(root: Self.root) }

            try store.save(ReviewDraft(), root: Self.root)

            #expect(MigrationBackup.readLedger(for: file)?.stage == .backedUp)
        }
    }

    /// A draft this build cannot read, and the mark the name of its
    /// set-aside copy carries.
    struct Unreadable: CustomTestStringConvertible, Sendable {
        let name: String
        let json: String
        /// What the set-aside copy's name carries.
        let setAside: String

        var testDescription: String {
            name
        }
    }

    static let unreadable = [
        Unreadable(
            name: "a version 1 comment with no fingerprint",
            json: #"{"version":1,"comments":[{"id":"8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21","#
                + #""file":{"path":"a","layer":"staged","status":"M"}}]}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            // A comment's position spread across `rowID` and `endOldLine`
            // rather than gathered into an anchor.
            name: "a version 1 comment in an older shape",
            json: """
            {"version":1,"comments":[{"id":"DF807E9F-D560-41FB-9F4F-5AD0374FC076",
             "file":{"path":"a.swift","layer":"unstaged","status":"M"},"fingerprint":"abc123",
             "rowID":8,"endRowID":10,"oldLine":194,"endOldLine":196,"code":"let x = 1","body":"Explain this."}]}
            """,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 comment that is not an object",
            json: #"{"version":1,"comments":["not a comment"]}"#,
            setAside: ".bak-decode-failed-"
        ),
        // Version 1 refused a draft whose lists were not lists; read as
        // empty, the draft would come out valid with its comments gone.
        Unreadable(
            name: "a version 1 draft whose comments are an object",
            json: #"{"version":1,"comments":{"a":1}}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 draft whose comments are a string",
            json: #"{"version":1,"comments":"none"}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 draft with no comments key",
            json: #"{"version":1}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 draft whose marks are a list",
            json: #"{"version":1,"comments":[],"viewed":[1]}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 draft with a mark that is not an object",
            json: #"{"version":1,"comments":[],"viewed":{"turn:a.swift":true}}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(
            name: "a version 1 draft whose open file is not a string",
            json: #"{"version":1,"comments":[],"lastFileID":7}"#,
            setAside: ".bak-decode-failed-"
        ),
        Unreadable(name: "a version no step reaches", json: #"{"version":0,"comments":[]}"#, setAside: ".bak-"),
        Unreadable(
            name: "a newer build's draft",
            json: #"{"version":3,"comments":[],"somethingNew":true}"#,
            setAside: ".bak-newer-version-"
        )
    ]

    /// A draft this build cannot read is refused rather than read partly,
    /// and set aside rather than migrated: no copy is taken for a migration
    /// and no ledger is written.
    @Test(arguments: unreadable)
    func aDraftThisBuildCannotRead_isSetAside_withNoCopyOrLedger(_ draft: Unreadable) throws {
        try withTempDir { directory in
            let file = try Self.write(draft.json, in: directory)

            #expect(throws: ReviewError.self) { try FileReviewDraftStore(directory: directory).load(root: Self.root) }

            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(MigrationBackup.readLedger(for: file) == nil)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(!names.contains { $0.contains(".pre-v2") })
            #expect(names.contains { $0.contains(draft.setAside) })
        }
    }

    /// Run as root, the folder below stays writable and there is nothing to
    /// test.
    @Test(.disabled(if: geteuid() == 0, "root writes into a read-only folder"))
    func noCopyCanBeKept_soTheOriginalStays_andTheDraftIsNotSaved() throws {
        try withTempDir { directory in
            let original = #"{"version":1,"comments":[]}"#
            let file = try Self.write(original, in: directory)
            // A folder nothing new can be written into.
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

            do {
                _ = try FileReviewDraftStore(directory: directory).load(root: Self.root)
                Issue.record("a draft migrated without a copy must not count as saved")
            } catch let ReviewDraftLoadError.migratedWithoutCopy(draft) {
                #expect(draft.version == 2)
            }

            #expect(try Data(contentsOf: file) == Data(original.utf8))
        }
    }

    @Test func aVersion2Draft_roundTripsThroughTheStore() throws {
        try withTempDir { directory in
            let store = FileReviewDraftStore(directory: directory)
            let file = ReviewFile(path: "a.swift", layer: .turn, status: .modified)
            let comment = ReviewComment(
                scopeIDs: ["turn:abc", "turns:def"],
                file: file,
                fingerprint: "f",
                anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 1),
                code: "x",
                body: "kept for two scopes"
            )
            let turn = try TurnSummaryFixture.turn(
                "T1",
                changes: TurnSummaryFixture.changedFiles,
                endTree: SnapshotTree(tree: TurnSummaryFixture.tree("e", 1), root: "/repo"),
                extras: .init(beginTree: SnapshotTree(tree: TurnSummaryFixture.tree("b", 1), root: "/repo"))
            )
            let range = try #require(ReviewTurnRange(turns: [turn]))
            let draft = ReviewDraft(
                comments: [comment],
                viewed: ["turn:abc": [file.id: ReviewViewMark(added: 1, removed: 0, markedAt: Date(timeIntervalSince1970: 0))]],
                lastFileID: ["turn:abc": file.id],
                ranges: [range]
            )

            try store.save(draft, root: Self.root)
            let read = try #require(try store.load(root: Self.root))

            #expect(read.comments == [comment])
            #expect(read.viewed == draft.viewed)
            #expect(read.lastFileID == draft.lastFileID)
            #expect(read.ranges == [range])
        }
    }

    private static func version(of file: URL) -> Int? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return FileReviewDraftStore.migrator.version(of: data)
    }

    /// The names a stored draft is read by, written out rather than derived
    /// from the type.
    ///
    /// `ReviewComment` and `ReviewDraft` code themselves through synthesized
    /// keys, so every property name is part of the file format: renaming one
    /// compiles, passes every test that saves and reloads through the store,
    /// and orphans the drafts already on disk. This decodes a draft written by
    /// hand in the shape the store claims to read, so a rename fails here
    /// instead.
    @MainActor
    @Test func aDraftIsReadByTheNamesItWasWrittenWith() throws {
        try withTempDir { directory in
            let root = URL(fileURLWithPath: "/tmp/weir-review-schema")
            let drafts = FileReviewDraftStore(directory: directory)
            let json = """
            {
              "version": 1,
              "comments": [
                {
                  "id": "8B2D3B22-3E0B-4D2E-9E33-3F0C4E1F9A21",
                  "file": {
                    "path": "Weir/App/WeirApp.swift",
                    "layer": "unstaged",
                    "status": "M"
                  },
                  "fingerprint": "abc123",
                  "anchor": { "lineID": 7, "newLine": 12 },
                  "code": "let x = 1",
                  "body": "Why 1?"
                }
              ]
            }
            """
            try Data(json.utf8).write(to: FileReviewDraftStore.url(root: root, directory: directory))

            let draft = try #require(try drafts.load(root: root))
            let comment = try #require(draft.comments.first)
            #expect(comment.file.path == "Weir/App/WeirApp.swift")
            #expect(comment.file.layer == .unstaged)
            #expect(comment.file.status == .modified)
            #expect(comment.fingerprint == "abc123")
            #expect(comment.lineID == 7)
            #expect(comment.anchor.newLine == 12)
            #expect(comment.anchor.oldLine == nil)
            #expect(comment.code == "let x = 1")
            #expect(comment.body == "Why 1?")
            // A single-line comment, a comment in the unified layout, a
            // comment from before markers were stored, and a comment nobody
            // has acted on all read as absent keys rather than as a file the
            // store has to refuse.
            #expect(comment.end == nil)
            #expect(comment.side == nil)
            #expect(comment.codeMarkers == nil)
            #expect(comment.insertedAt == nil)
            #expect(comment.resolvedAt == nil)
            // A version 1 draft is brought forward: its working-copy comment
            // keeps its scope, and keys it never had read as empty.
            #expect(comment.scopeIDs == ["uncommitted"])
            #expect(draft.viewed.isEmpty)
            // A draft written before review remembered where the reader was
            // has no key for it, and reading it must not be how that draft
            // stops loading.
            #expect(draft.lastFileID.isEmpty)
        }
    }
}

struct ReviewDraftCapacityTests {
    @Test func aResolvedBacklogReportsAnActionableErrorWithoutReplacingTheDraft() throws {
        try withTempDir { directory in
            let storage = FileReviewDraftStore(directory: directory)
            try storage.save(ReviewDraft(lastFileID: ["uncommitted": "saved"]), root: directory)
            let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
            let comments = (0..<400).map { index in
                ReviewComment(
                    file: file, fingerprint: "f", anchor: ReviewAnchor(lineID: index, oldLine: nil, newLine: index + 1),
                    code: String(repeating: "x", count: ReviewSession.maxCodeExcerpt),
                    body: String(repeating: "x", count: ReviewSession.maxCommentBytes), resolvedAt: Date()
                )
            }
            #expect(throws: ReviewError.resolvedBacklogTooLarge) {
                try storage.save(ReviewDraft(comments: comments), root: directory)
            }
            let saved = try storage.load(root: directory)
            #expect(saved?.lastFileID["uncommitted"] == "saved")
        }
    }
}
