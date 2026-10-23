// SidebarSectionRuleTests.swift
// Limpid — which of the working rows, the rows ready to clean up, and the other worktrees a row is listed in.

import Foundation
import Testing
@testable import Limpid

struct SidebarSectionRuleTests {
    private typealias Facts = SidebarSectionRule.Facts

    /// One case of the table: what the row holds, and where it is listed.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let facts: SidebarSectionRule.Facts
        let section: SidebarSection

        var testDescription: String {
            name
        }
    }

    static let cases: [Case] = [
        Case(name: "a tab keeps an agent's worktree working", facts: Facts(admission: .discovered, hasTabs: true), section: .working),
        Case(name: "an item keeps an agent's worktree working", facts: Facts(admission: .discovered, hasItems: true), section: .working),
        Case(name: "a row Limpid made is working without a tab", facts: Facts(admission: .created), section: .working),
        Case(name: "a row the person opened is working without a tab", facts: Facts(admission: .opened), section: .working),
        Case(name: "an unopened worktree Git reports is other", facts: Facts(admission: .discovered), section: .other),
        Case(
            name: "an unopened worktree stays other with a merged request",
            facts: Facts(admission: .discovered, prState: .merged),
            section: .other
        ),
        Case(
            name: "merged, with nothing open, is ready to clean up",
            facts: Facts(admission: .created, prState: .merged),
            section: .cleanable
        ),
        Case(
            name: "closed, with nothing open, is ready to clean up",
            facts: Facts(admission: .opened, prState: .closed),
            section: .cleanable
        ),
        Case(
            name: "merged with files left uncommitted is working",
            facts: Facts(admission: .created, prState: .merged, uncommittedFiles: 2),
            section: .working
        ),
        Case(
            name: "merged with a tab open is working",
            facts: Facts(admission: .created, hasTabs: true, prState: .merged),
            section: .working
        ),
        Case(name: "an open request is working", facts: Facts(admission: .created, prState: .open), section: .working),
        Case(
            name: "the folder is always working",
            facts: Facts(isMainFolder: true, admission: .discovered, prState: .merged),
            section: .working
        ),
        Case(name: "a missing worktree is always working", facts: Facts(admission: .discovered, isMissing: true), section: .working),
        Case(name: "the selected row is always working", facts: Facts(admission: .discovered, isSelected: true), section: .working),
        Case(
            name: "the selected row is working even when merged",
            facts: Facts(admission: .created, isSelected: true, prState: .merged),
            section: .working
        ),
        // Not admitted yet: placed by what it holds, as every row was before.
        Case(name: "an unknown admission with nothing open is working", facts: Facts(admission: nil), section: .working),
        Case(name: "an unknown admission with a tab is working", facts: Facts(admission: nil, hasTabs: true), section: .working),
        Case(
            name: "an unknown admission, merged, is ready to clean up",
            facts: Facts(admission: nil, prState: .merged),
            section: .cleanable
        )
    ]

    @Test(arguments: cases)
    func aRow_isListedWhereWhatItHoldsPutsIt(_ example: Case) {
        #expect(SidebarSectionRule.section(example.facts) == example.section)
    }
}
