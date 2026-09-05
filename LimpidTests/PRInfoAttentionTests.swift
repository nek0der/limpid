// PRInfoAttentionTests.swift
// Limpid — which requests the sidebar marks without being asked.
//
// `needsAttention` is the whole of what survives when a user asks the
// sidebar for fewer marks, so it is worth pinning: too generous and
// the setting stops reducing anything; too strict and a red CI run
// goes unseen until the user hovers.
//
// The cases below are stated in terms of what a user would expect to
// be flagged, not in terms of the current one-line implementation, so
// they keep their meaning if review state joins later.

import Foundation
import Testing
@testable import Limpid

@Suite("PRInfo.needsAttention")
struct PRInfoAttentionTests {

    /// The case the predicate exists for.
    @Test(
        "a failing check needs attention in any state",
        arguments: [PRState.open, .merged, .closed]
    )
    func needsAttention_failingChecks_isTrue(state: PRState) {
        #expect(PRInfoFixture.make(state: state, checks: .failure).needsAttention)
    }

    /// An ordinary open request is the common case, and it is exactly
    /// what the reduced mode is meant to drop.
    @Test(
        "a healthy or running request stays quiet",
        arguments: [PRChecksConclusion.success, .pending],
        [PRState.open, .merged, .closed]
    )
    func needsAttention_nonFailingChecks_isFalse(
        conclusion: PRChecksConclusion,
        state: PRState
    ) {
        #expect(!PRInfoFixture.make(state: state, checks: conclusion).needsAttention)
    }

    /// A repository with no CI reports no checks at all. That is not
    /// a problem to flag — it is the absence of information.
    @Test("no checks at all is not attention-worthy")
    func needsAttention_noChecks_isFalse() {
        #expect(!PRInfoFixture.make().needsAttention)
    }

    /// Draft is a state of the request, not of its checks, so it must
    /// not move the answer in either direction: it neither raises
    /// attention on its own nor suppresses a failing check.
    @Test("draft does not move the answer either way")
    func needsAttention_draft_isTransparent() {
        #expect(!PRInfoFixture.make(isDraft: true).needsAttention)
        #expect(PRInfoFixture.make(isDraft: true, checks: .failure).needsAttention)
    }
}
