// PRStatusFetcherDecodeTests.swift
// Limpid — Swift Testing coverage for `PRStatusFetcher.decode`.
//
// Two payload shapes reach this decoder and they agree on almost
// nothing: `gh` returns the fields we name, `glab` returns GitLab's
// whole merge-request object plus whatever diagnostics it felt like
// printing. Both are pinned here — state mapping, the draft flag,
// check aggregation, and the failure modes each forge has.
//
// Pure JSON in, value out: no IO, no CLI invocation, no network.

import Foundation
import Testing
@testable import Limpid

@Suite("PRStatusFetcher")
struct PRStatusFetcherDecodeTests {

    // MARK: - State mapping

    @Test(
        "maps gh state strings to PRState",
        arguments: [
            ("OPEN", PRState.open),
            ("MERGED", PRState.merged),
            ("CLOSED", PRState.closed),
            // Unknown future raw value: degrade gracefully to .open so
            // the row stays tinted rather than disappearing.
            ("SOMETHING_NEW", PRState.open)
        ]
    )
    func decode_state_mapsKnownAndFallsBackOnUnknown(
        rawState: String,
        expected: PRState
    ) throws {
        let json = makeMinimalJSON(state: rawState)
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        #expect(info.state == expected)
    }

    @Test("isDraft flag is honored")
    func decode_isDraft_isPropagated() throws {
        let json = makeMinimalJSON(state: "OPEN", isDraft: true)
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        #expect(info.isDraft)
    }

    // MARK: - Checks aggregation

    @Test("rollup with all successes resolves to .success")
    func decode_checksAllSuccess_aggregatesToSuccess() throws {
        let json = makeJSON(
            checks: [
                #"{"conclusion": "SUCCESS", "status": "COMPLETED"}"#,
                #"{"conclusion": "SUCCESS", "status": "COMPLETED"}"#
            ]
        )
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        let counts = try #require(info.checks?.counts)
        #expect(info.checks?.conclusion == .success)
        #expect(counts.passed == 2)
        #expect(counts.total == 2)
    }

    @Test("any failure dominates pending and success")
    func decode_checksOneFailure_aggregatesToFailure() throws {
        let json = makeJSON(
            checks: [
                #"{"conclusion": "SUCCESS", "status": "COMPLETED"}"#,
                #"{"conclusion": "FAILURE", "status": "COMPLETED"}"#,
                #"{"conclusion": null, "status": "IN_PROGRESS"}"#
            ]
        )
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        let counts = try #require(info.checks?.counts)
        #expect(info.checks?.conclusion == .failure)
        #expect(counts.passed == 1)
        #expect(counts.total == 3)
    }

    @Test("pending dominates success when no failures")
    func decode_checksPendingWithoutFailure_aggregatesToPending() throws {
        let json = makeJSON(
            checks: [
                #"{"conclusion": "SUCCESS", "status": "COMPLETED"}"#,
                #"{"conclusion": null, "status": "IN_PROGRESS"}"#
            ]
        )
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        let counts = try #require(info.checks?.counts)
        #expect(info.checks?.conclusion == .pending)
        #expect(counts.passed == 1)
    }

    @Test("StatusContext rows (state field instead of conclusion) decode")
    func decode_statusContextRow_normalizesViaStateField() throws {
        // StatusContext objects expose `state`, not `conclusion`.
        let json = makeJSON(
            checks: [
                #"{"state": "SUCCESS"}"#,
                #"{"state": "FAILURE"}"#
            ]
        )
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        let counts = try #require(info.checks?.counts)
        #expect(info.checks?.conclusion == .failure)
        #expect(counts.passed == 1)
    }

    @Test("missing rollup yields nil checks (no-CI case)")
    func decode_noRollup_returnsNilChecks() throws {
        let json = makeMinimalJSON(state: "OPEN")
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        #expect(info.checks == nil)
    }

    @Test("empty rollup yields nil checks")
    func decode_emptyRollup_returnsNilChecks() throws {
        let json = makeJSON(checks: [])
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        #expect(info.checks == nil)
    }

    // MARK: - Failure modes

    @Test("empty stdout returns nil")
    func decode_emptyStdout_returnsNil() {
        #expect(PRStatusFetcher.decode(stdout: "", forge: .gitHub) == nil)
    }

    @Test("malformed JSON returns nil rather than throwing")
    func decode_invalidJSON_returnsNil() {
        #expect(PRStatusFetcher.decode(stdout: "not json {{", forge: .gitHub) == nil)
    }

    @Test("missing required field returns nil")
    func decode_missingNumber_returnsNil() {
        let json = """
        {"state": "OPEN", "isDraft": false, "title": "x", "url": "https://example.com/pr/1"}
        """
        #expect(PRStatusFetcher.decode(stdout: json, forge: .gitHub) == nil)
    }

    // MARK: - Unknown status vocabulary

    /// The fetcher promises that an unrecognized CI status degrades to
    /// `.pending`, never to `.success` — a future forge state must not
    /// silently render as "everything passes".
    @Test("unknown check status degrades to pending, not success")
    func decode_unknownCheckStatus_degradesToPending() throws {
        let json = makeJSON(checks: [#"{"status": "SOME_FUTURE_STATE"}"#])
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitHub))
        #expect(info.checks?.conclusion == .pending)
    }

    // MARK: - GitLab

    @Test(
        "maps glab state strings to PRState",
        arguments: [
            ("opened", PRState.open),
            ("merged", PRState.merged),
            ("closed", PRState.closed),
            // `locked` means the discussion is locked; the request
            // itself is still open.
            ("locked", PRState.open)
        ]
    )
    func decodeGitLab_state_mapsIncludingLocked(
        rawState: String,
        expected: PRState
    ) throws {
        let info = try #require(
            PRStatusFetcher.decode(stdout: makeGitLabJSON(state: rawState), forge: .gitLab)
        )
        #expect(info.state == expected)
    }

    @Test("glab payload uses iid as the user-facing number")
    func decodeGitLab_usesIidNotId() throws {
        let info = try #require(
            PRStatusFetcher.decode(stdout: makeGitLabJSON(state: "opened"), forge: .gitLab)
        )
        // The fixture's global `id` is deliberately different so a
        // regression that reads the wrong field is unambiguous.
        #expect(info.number == 7)
        #expect(info.forge == .gitLab)
    }

    @Test(
        "maps head_pipeline status to a conclusion without counts",
        arguments: [
            ("success", PRChecksConclusion.success),
            ("failed", PRChecksConclusion.failure),
            ("canceled", PRChecksConclusion.failure),
            ("running", PRChecksConclusion.pending),
            ("manual", PRChecksConclusion.pending),
            ("skipped", PRChecksConclusion.success),
            ("some_future_state", PRChecksConclusion.pending)
        ]
    )
    func decodeGitLab_pipelineStatus_mapsToConclusion(
        rawStatus: String,
        expected: PRChecksConclusion
    ) throws {
        let json = makeGitLabJSON(state: "opened", pipelineStatus: rawStatus)
        let info = try #require(PRStatusFetcher.decode(stdout: json, forge: .gitLab))
        let checks = try #require(info.checks)
        #expect(checks.conclusion == expected)
        // GitLab exposes no per-job breakdown through `glab mr view`,
        // so counts must stay absent rather than being faked as zeroes.
        #expect(checks.counts == nil)
    }

    @Test("glab payload without a pipeline yields nil checks")
    func decodeGitLab_noPipeline_returnsNilChecks() throws {
        let info = try #require(
            PRStatusFetcher.decode(stdout: makeGitLabJSON(state: "opened"), forge: .gitLab)
        )
        #expect(info.checks == nil)
    }

    @Test("glab draft flag is honored and defaults to false when absent")
    func decodeGitLab_draft() throws {
        let drafted = try #require(
            PRStatusFetcher.decode(
                stdout: makeGitLabJSON(state: "opened", isDraft: true),
                forge: .gitLab
            )
        )
        #expect(drafted.isDraft)
        // `draft` is absent on older GitLab versions; absence is not
        // "draft".
        let legacy = """
        {"iid": 7, "state": "opened", "title": "x",
         "web_url": "https://gitlab.example.com/acme/app/-/merge_requests/7"}
        """
        let decoded = try #require(PRStatusFetcher.decode(stdout: legacy, forge: .gitLab))
        #expect(!decoded.isDraft)
    }

    // MARK: - Noisy stdout

    /// A CLI that put a diagnostic on stdout, before or after the
    /// JSON, would fail `JSONDecoder` on the surrounding bytes and
    /// disable that forge entirely while every synthetic fixture kept
    /// passing. Both CLIs keep their diagnostics on stderr today —
    /// this pins the tolerance rather than a reproduction.
    ///
    /// Note the trailing line contains braces of its own, so a naive
    /// "slice to the last `}`" would swallow it.
    @Test("glab output with a trailing telemetry line still decodes")
    func decodeGitLab_trailingDiagnosticLine_decodes() throws {
        let stdout = """
        {"id":901,"iid":42,"state":"opened","draft":false,\
        "title":"fix: tighten the retry budget",\
        "web_url":"https://gitlab.example.com/acme/app/-/merge_requests/42",\
        "head_pipeline":{"id":2069115947,"status":"success"}}
        Could not send telemetry data: POST https://gitlab.example.com/api/v4/usage_data/track_event: \
        401 {message: 401 Unauthorized}
        """
        let info = try #require(PRStatusFetcher.decode(stdout: stdout, forge: .gitLab))
        #expect(info.number == 42)
        #expect(info.state == .open)
        #expect(info.checks?.conclusion == .success)
        #expect(info.forge == .gitLab)
    }

    /// Braces inside a string value must not close the object early —
    /// the scanner has to track string and escape state, not just
    /// count braces.
    ///
    /// The brace sits unbalanced *and* between escaped quotes, which
    /// is what makes the fixture discriminate on both counts. Drop the
    /// escape tracking and the first `\"` reads as a real quote, so
    /// the scanner believes it has left the string and takes the `}`
    /// as the object's end. Drop the string tracking and it never
    /// entered one. A balanced brace, or one outside the escaped pair,
    /// leaves a naive scanner landing on the same closing brace as the
    /// real one and pins nothing.
    @Test("braces and escaped quotes inside values do not truncate the object")
    func decode_bracesInsideStringValues_parseCorrectly() throws {
        let stdout = """
        noise before
        {"iid":9,"state":"opened","draft":false,\
        "title":"fix: stop logging a bare \\"}\\" in the diff",\
        "web_url":"https://gitlab.example.com/acme/app/-/merge_requests/9"}
        noise after {still not json}
        """
        let info = try #require(PRStatusFetcher.decode(stdout: stdout, forge: .gitLab))
        #expect(info.number == 9)
        #expect(info.title == #"fix: stop logging a bare "}" in the diff"#)
    }

    @Test("stdout with no JSON object at all returns nil")
    func decode_noObjectInStdout_returnsNil() {
        #expect(PRStatusFetcher.firstJSONObject(in: "just a warning line") == nil)
        #expect(PRStatusFetcher.decode(stdout: "just a warning line", forge: .gitLab) == nil)
    }

    @Test("an unterminated object yields no candidate slice")
    func firstJSONObject_unterminatedObject_returnsNil() {
        #expect(PRStatusFetcher.firstJSONObject(in: #"{"iid": 9, "state": "opened""#) == nil)
    }

    @Test("a GitHub payload does not decode as GitLab")
    func decode_forgeMismatch_returnsNil() {
        let github = makeMinimalJSON(state: "OPEN")
        #expect(PRStatusFetcher.decode(stdout: github, forge: .gitLab) == nil)
    }

    // MARK: - Fixture builders

    /// Minimal valid payload — used everywhere we don't care about
    /// checks. Mirrors the field list `PRStatusFetcher` asks `gh` for.
    private func makeMinimalJSON(state: String, isDraft: Bool = false) -> String {
        """
        {
          "number": 142,
          "state": "\(state)",
          "isDraft": \(isDraft),
          "title": "Show PR status in the sidebar",
          "url": "https://github.example.com/acme/app/pull/142"
        }
        """
    }

    /// Minimal `glab mr view --output json` payload. GitLab returns
    /// its full API object; we model only the fields the decoder
    /// names, plus a deliberately different global `id` so a decoder
    /// that reads the wrong number field fails loudly.
    private func makeGitLabJSON(
        state: String,
        isDraft: Bool = false,
        pipelineStatus: String? = nil
    ) -> String {
        let pipeline = pipelineStatus.map {
            #", "head_pipeline": {"id": 900, "status": "\#($0)"}"#
        } ?? ""
        return """
        {
          "id": 5551,
          "iid": 7,
          "state": "\(state)",
          "draft": \(isDraft),
          "title": "Show PR status in the sidebar",
          "web_url": "https://gitlab.example.com/acme/app/-/merge_requests/7"\(pipeline)
        }
        """
    }

    /// Variant that injects a statusCheckRollup. Each element of
    /// `checks` is a raw JSON object literal so tests can mix
    /// `conclusion` / `state` / `status` shapes.
    private func makeJSON(checks: [String]) -> String {
        let rollup = checks.joined(separator: ", ")
        return """
        {
          "number": 142,
          "state": "OPEN",
          "isDraft": false,
          "title": "Show PR status in the sidebar",
          "url": "https://github.example.com/acme/app/pull/142",
          "statusCheckRollup": [\(rollup)]
        }
        """
    }
}
