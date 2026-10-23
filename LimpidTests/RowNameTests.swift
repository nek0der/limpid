// RowNameTests.swift
// Limpid — a row is named by the person's name, its conversation, its branch, then its folder.

import Foundation
import Testing
@testable import Limpid

struct RowNameTests {
    @Test func theNameAPersonGave_comesFirst() {
        let name = RowName.make(manual: "Release prep", conversation: "Add tests", branch: "feat/x", folder: "repo-feat-x")
        #expect(name == RowName(text: "Release prep", source: .manual))
    }

    @Test func theConversation_comesBeforeTheBranch() {
        let name = RowName.make(manual: nil, conversation: "Add tests", branch: "feat/x", folder: "repo-feat-x")
        #expect(name == RowName(text: "Add tests", source: .conversation))
    }

    @Test func theBranch_comesBeforeTheFolder() {
        let name = RowName.make(manual: nil, conversation: nil, branch: "feat/x", folder: "repo-feat-x")
        #expect(name == RowName(text: "feat/x", source: .branch))
    }

    /// A detached HEAD has no branch: the folder names the row.
    @Test func aDetachedRow_isNamedByItsFolder() {
        let name = RowName.make(manual: nil, conversation: nil, branch: nil, folder: "alpha-detached")
        #expect(name == RowName(text: "alpha-detached", source: .folder))
    }

    /// An empty name counts as none, so clearing a name hands the row back
    /// to the next.
    @Test func anEmptyName_handsTheRowToTheNext() {
        let name = RowName.make(manual: "", conversation: "", branch: "", folder: "repo")
        #expect(name == RowName(text: "repo", source: .folder))
    }
}
