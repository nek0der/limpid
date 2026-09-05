// PRInfoFixture.swift
// Limpid — one builder for the `PRInfo` values the pull-request
// suites assert on.
//
// Four suites were each carrying their own `makeInfo`, two of them
// byte-identical. That is the shape of drift: a field added to
// `PRInfo` has to be threaded through every copy, and a suite that
// misses one starts testing a slightly different object than its
// neighbours while still reading as though they agree.
//
// Defaults describe the ordinary case — an open, non-draft request
// with no checks reported — so a test names only the axis it is
// about.

import Foundation
@testable import Limpid

enum PRInfoFixture {
    static func make(
        number: Int = 1,
        state: PRState = .open,
        isDraft: Bool = false,
        checks: PRChecksConclusion? = nil,
        counts: PRChecks.Counts? = nil,
        forge: ForgeKind = .gitHub,
        title: String = "Show PR status in the sidebar"
    ) -> PRInfo {
        PRInfo(
            number: number,
            state: state,
            isDraft: isDraft,
            title: title,
            // A file URL keeps the fixture offline and obviously fake;
            // nothing under test dereferences it.
            url: URL(fileURLWithPath: "/tmp/limpid/pull/\(number)"),
            forge: forge,
            checks: checks.map { PRChecks(conclusion: $0, counts: counts) }
        )
    }
}
