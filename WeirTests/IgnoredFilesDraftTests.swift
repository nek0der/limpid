// IgnoredFilesDraftTests.swift
// Weir — Project Settings' list of the files to copy into new worktrees: what is saved, what is marked, and the ignored files' menu.

import Foundation
import Testing
@testable import Weir

struct IgnoredFilesDraftTests {
    @Test func theRows_saveWhatCanBeUsed_andMarkTheRest() {
        var draft = IgnoredFilesDraft(patterns: [".env"])
        let empty = draft.add()
        let copy = draft.add("./.env")
        let outside = draft.add("../secret")
        let git = draft.add(".git/config")
        #expect(draft.problem(of: empty, editing: empty) == nil, "a row being typed in is not marked")
        #expect(draft.problem(of: empty) == .empty)
        #expect(draft.problem(of: copy) == .duplicate)
        #expect(draft.problem(of: outside) == .unsafe(.leavesFolder))
        #expect(draft.problem(of: git) == .unsafe(.namesGitFolder))
        #expect(draft.patterns == [".env"])
    }

    @Test func anEmptyList_savesNil_asAProjectThatNamedNone() {
        var draft = IgnoredFilesDraft(patterns: [".env"])
        draft.remove(draft.rows[0].id)
        #expect(draft.patterns == nil)
        #expect(IgnoredFilesDraft(patterns: nil).rows.isEmpty)
    }

    /// Opening the sheet writes nothing; an edit that changes nothing
    /// saved (an empty row added) writes nothing either.
    @Test func onlyAnEditThatChangesWhatIsSaved_saves() {
        let opened = IgnoredFilesDraft(patterns: [".env"])
        var edited = opened
        edited.add()
        #expect(IgnoredFilesDraft.save(from: opened, to: edited) == .nothing)
        edited.setText("config/master.key", of: edited.rows[1].id)
        #expect(IgnoredFilesDraft.save(from: opened, to: edited) == .patterns([".env", "config/master.key"]))
    }

    @Test func theIgnoredFilesMenu_addsAndRemovesTheRowNamingAPath() {
        var draft = IgnoredFilesDraft(patterns: nil)
        draft.toggle("node_modules/")
        #expect(draft.contains("node_modules/"))
        #expect(draft.patterns == ["/node_modules/"], "anchored: that one folder, no other of its name")
        draft.toggle("node_modules/")
        #expect(!draft.contains("node_modules/"))
        #expect(draft.rows.isEmpty)
    }
}
