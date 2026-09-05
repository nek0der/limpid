// PRChecksConclusionTests.swift
// Limpid — collapsing two forges' CI vocabularies into three outcomes.
//
// The decoders only ever reach this initializer with whatever the CLI
// printed, so the vocabulary is exercised in production far more
// widely than any JSON fixture covers. Two mistakes here are silent
// and costly:
//
//   - A real failure demoted to `.pending` drops the red badge, and
//     under "only rows needing attention" the row then shows nothing
//     at all — the setting's whole purpose, inverted.
//   - A settled state promoted to `.pending` pins
//     `PRStatusSyncer.currentInterval` to the active cadence, so every
//     row keeps spawning a CLI every 45 seconds for the rest of the
//     session.
//
// Cases are listed by the forge that emits them so a reader can check
// them against that forge's docs rather than against this file.

import Foundation
import Testing
@testable import Limpid

@Suite("PRChecksConclusion(rawStatus:)")
struct PRChecksConclusionTests {

    @Test(
        "a settled, passing run reads as success",
        arguments: [
            // GitHub `CheckConclusionState`. NEUTRAL, SKIPPED and
            // STALE are settled and non-blocking, so they belong with
            // the passes rather than holding the fast cadence open.
            "SUCCESS", "NEUTRAL", "SKIPPED", "STALE",
            // GitLab pipeline statuses.
            "success", "skipped"
        ]
    )
    func conclusion_passingVocabulary_isSuccess(raw: String) {
        #expect(PRChecksConclusion(rawStatus: raw) == .success)
    }

    @Test(
        "anything that ended without passing reads as failure",
        arguments: [
            // GitHub `CheckConclusionState`, in full apart from the
            // four that pass. ERROR is from `StatusState`, which the
            // same rollup carries for commit statuses.
            "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR",
            // GitHub spells a cancellation with two Ls, GitLab with
            // one. Both have to land here or a cancelled run holds the
            // fast cadence open.
            "CANCELLED", "canceled",
            // GitLab.
            "failed"
        ]
    )
    func conclusion_failingVocabulary_isFailure(raw: String) {
        #expect(PRChecksConclusion(rawStatus: raw) == .failure)
    }

    @Test(
        "a run still going reads as pending",
        arguments: [
            "PENDING", "QUEUED", "IN_PROGRESS", "REQUESTED", "WAITING", "EXPECTED",
            "created", "waiting_for_resource", "waiting_for_callback",
            "preparing", "running", "canceling", "manual", "scheduled"
        ]
    )
    func conclusion_runningVocabulary_isPending(raw: String) {
        #expect(PRChecksConclusion(rawStatus: raw) == .pending)
    }

    /// The rule the initializer's doc states outright: an unrecognized
    /// state must never render as "everything passed" on the strength
    /// of us not knowing what it means. Absent and empty go the same
    /// way — `gh` marshals `conclusion` as a Go string, so a check that
    /// has not finished can arrive as `""` rather than `null`.
    @Test(
        "an unknown, absent or empty state is never success",
        arguments: [nil, "", "SOMETHING_NEW_IN_2027", "   "]
    )
    func conclusion_unknownVocabulary_isPending(raw: String?) {
        #expect(PRChecksConclusion(rawStatus: raw) == .pending)
    }

    /// GitLab's statuses arrive lowercase and GitHub's uppercase, so
    /// the normalization is load-bearing on both sides rather than
    /// defensive on one.
    @Test("matching is case-insensitive in both directions")
    func conclusion_mixedCase_matchesTheSameOutcome() {
        #expect(PRChecksConclusion(rawStatus: "Success") == .success)
        #expect(PRChecksConclusion(rawStatus: "failure") == .failure)
        #expect(PRChecksConclusion(rawStatus: "TiMeD_OuT") == .failure)
    }
}
