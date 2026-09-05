// PRInfo.swift
// Limpid — the pull request a checkout's branch points at.
//
// "Pull request" is the umbrella term here even though GitLab calls
// them merge requests. That follows the convention every cross-forge
// abstraction settled on (Flux's go-git-providers exposes
// `PullRequest` / `PullRequestClient`, git-pkgs/forge exposes
// `PullRequests()`, magit/forge stores `pullreq` records) because
// GitHub, Gitea, Forgejo, and Bitbucket all say "pull request" and
// only GitLab diverges. Coining a neutral third term would be
// accurate for nobody and unfamiliar to everybody.
//
// Equatable so the store can dedupe write-backs and avoid Observation
// churn when a refetch returns the same value; Sendable (implicitly,
// via its members) so the syncer can hand a snapshot from a background
// task into the @MainActor store.
//
// Every field here is one the sidebar or the hover card renders. That is
// a deliberate constraint rather than an accident: a stored-but-unread
// field still takes part in `Equatable`, so the forge bumping it —
// a new comment, a label change — would defeat the de-duplication
// above and churn the UI for a render that cannot look any different.

import Foundation

struct PRInfo: Equatable {
    /// Number as the forge's own UI shows it — `number` on GitHub,
    /// `iid` (the per-project internal id) on GitLab.
    var number: Int
    var state: PRState
    var isDraft: Bool
    /// Title shown in the hover card. We don't truncate or sanitize here
    /// — `Text` handles line clamping at render time.
    var title: String
    var url: URL
    /// Which forge this came from. Drives the card's link label so
    /// a GitLab user isn't told to "open on GitHub".
    var forge: ForgeKind
    /// Nil when the forge reports no CI at all for this branch. We
    /// distinguish "no checks" from "checks pending" because users who
    /// haven't wired CI need a calm UI, not a perpetual clock.
    var checks: PRChecks?
}

/// Subset of forge states we render distinctly. Draft-vs-open is a
/// boolean flag on the parent rather than its own case because both
/// forges model it that way.
///
/// GitLab's `locked` maps to `.open`: it means the discussion is
/// locked, not that the request is finished.
enum PRState {
    case open
    case closed
    case merged
}

/// CI status attached to a pull request.
///
/// The two forges disagree on shape. GitHub returns a *list* of checks
/// (`statusCheckRollup`) that we aggregate into counts; GitLab returns
/// a *single* pipeline status (`head_pipeline.status`) with no
/// per-check breakdown available from the CLI. Rather than fake counts
/// for GitLab — which would render as a confident "0/0 passed" — we
/// let `counts` be absent and have the card fall back to phrasing
/// that states the conclusion alone.
struct PRChecks: Equatable {
    var conclusion: PRChecksConclusion
    /// Absent when the forge exposes only an aggregate status.
    var counts: Counts?

    /// How many of the forge's checks passed, out of how many exist.
    /// A per-outcome breakdown would be fields nothing reads:
    /// `conclusion` above already says whether any failed.
    struct Counts: Equatable {
        var passed: Int
        var total: Int
    }
}

/// Tri-state because that is all the row acts on: only `.failure`
/// puts anything there, and the hover card separates the other two. There is deliberately no "no checks" case — that state
/// is carried by `PRInfo.checks == nil`, so a `PRChecks` value always
/// describes checks that actually exist.
enum PRChecksConclusion {
    case success
    case failure
    case pending

    /// Collapse a forge's CI vocabulary into the three outcomes the
    /// sidebar can express. Both forges report far more states than
    /// this, and they disagree on spelling, so the mapping lives here
    /// rather than being duplicated per decoder.
    ///
    /// Anything unrecognized becomes `.pending`, never `.success`: a
    /// state we have not seen before must not render as "everything
    /// passed" on the strength of us not knowing what it means.
    init(rawStatus: String?) {
        // `.success` is "settled and not a failure" rather than
        // "green": NEUTRAL, SKIPPED and STALE are all finished and
        // none of them blocks. Leaving them in the pending bucket
        // would be worse than inexact — a settled state read as
        // running holds `PRStatusSyncer` at its active cadence for as
        // long as the request exists.
        switch (rawStatus ?? "").uppercased() {
        case "SUCCESS", "NEUTRAL", "SKIPPED", "STALE":
            self = .success
        // GitHub spells a cancelled run with two Ls and GitLab with
        // one; both have to land here or a run nobody is waiting on
        // holds the syncer at its fast cadence.
        case "FAILURE", "FAILED", "TIMED_OUT", "ACTION_REQUIRED", "ERROR",
             "STARTUP_FAILURE", "CANCELLED", "CANCELED":
            self = .failure
        default:
            // GitHub: PENDING / QUEUED / IN_PROGRESS / REQUESTED /
            // WAITING / EXPECTED.
            // GitLab: created / waiting_for_resource /
            // waiting_for_callback / preparing / pending / running /
            // canceling / manual / scheduled.
            self = .pending
        }
    }
}

extension PRInfo {
    /// True when the request is in a state worth flagging on the row
    /// even by someone who has asked for fewer marks.
    ///
    /// The sidebar marks every request by default. This predicate is
    /// what remains visible once `showPRStatusOnlyWhenAttention` is
    /// on, for a user who would rather the column stayed sparse. The
    /// hover card is unaffected either way — it reports every
    /// request.
    ///
    /// A failing check is the only such state today. Review state
    /// belongs here too but is not fetched yet. The Settings footer
    /// names the members of this set outright, in both languages, so
    /// widening it means editing `Localizable.xcstrings` in the same
    /// change.
    var needsAttention: Bool {
        checks?.conclusion == .failure
    }
}
