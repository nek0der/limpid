// RowNameTests.swift
// Weir — a row is named by the person's name, its branch, its conversation, then its folder.

import Foundation
import Testing
@testable import Weir

struct RowNameTests {
    @Test func theNameAPersonGave_comesFirst() {
        let name = RowName.make(manual: "Release prep", conversation: "Add tests", branch: "feat/x", folder: "repo-feat-x")
        #expect(name == RowName(text: "Release prep", source: .manual))
    }

    @Test func theBranch_comesBeforeTheConversation() {
        let name = RowName.make(manual: nil, conversation: "Add tests", branch: "feat/x", folder: "repo-feat-x")
        #expect(name == RowName(text: "feat/x", source: .branch))
    }

    /// A detached HEAD has no branch: its conversation names the row.
    @Test func theConversation_comesBeforeTheFolder() {
        let name = RowName.make(manual: nil, conversation: "Add tests", branch: nil, folder: "alpha-detached")
        #expect(name == RowName(text: "Add tests", source: .conversation))
    }

    /// A detached HEAD no agent has run in is named by its folder.
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
