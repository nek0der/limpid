// PRStatusFetcher.swift
// Limpid — reads a checkout's linked pull request via the forge CLI.
//
// Separate from `GitProcess` because these CLIs are optional
// dependencies: the user may not have them installed, may not be
// authenticated, or may be offline. Every failure mode here resolves
// to "show nothing, and log at debug", which is a different posture
// than the `git` path that surfaces errors interactively.
//
// The two forges need separate decoders. `gh pr view --json a,b,c`
// lets us name the fields we want and returns a flat object shaped
// like our request. `glab mr view --output json` has no field
// selection and returns GitLab's full API object, so we pick fields
// out of a much larger payload. Their CI shapes differ more sharply
// still — see `PRChecks` for why `counts` is optional.

import Foundation
import OSLog

private let log = Logger.limpid("git.pr")

struct PRStatusFetcher {
    private let resolver: ForgeResolver
    private let locator: ToolLocator

    init(resolver: ForgeResolver, locator: ToolLocator) {
        self.resolver = resolver
        self.locator = locator
    }

    /// Ceiling on one CLI call. Long enough for a cold `gh` on a slow
    /// link, short enough that a hung binary cannot hold a sync tick.
    private static let timeout: Duration = .seconds(5)

    /// Resolve the pull request linked to `workingDirectory`, or
    /// `nil` when:
    ///   - the worktree has no remote, or its host isn't a forge we
    ///     support (resolved once and cached by `ForgeResolver`)
    ///   - the forge CLI is not installed
    ///   - the CLI exits non-zero (no PR linked, not authenticated,
    ///     rate limited, network down, …)
    ///   - JSON decode fails (unknown future shape)
    ///   - the call outlives `timeout`
    ///
    /// We deliberately do not `throw` — the sidebar mark is opt-in
    /// best-effort, not an interactive operation. Failures log at
    /// `.debug` so anyone diagnosing can use `log show`, but nothing
    /// reaches the UI.
    func fetch(workingDirectory: URL) async -> PRInfo? {
        guard let forge = await resolver.forge(for: workingDirectory) else { return nil }
        guard let executable = await locator.locate(forge.executableName) else {
            log.debug("\(forge.executableName, privacy: .public) not installed")
            return nil
        }
        let result = await runTool(
            executable: executable,
            arguments: Self.arguments(for: forge),
            workingDirectory: workingDirectory,
            environment: Self.quietEnvironment(for: forge),
            timeout: Self.timeout
        )
        guard let result else {
            log.debug("\(forge.executableName, privacy: .public) did not complete")
            return nil
        }
        guard result.isSuccess else {
            // "no pull requests found" exits non-zero, which is the
            // common case for a newly created branch.
            log.debug("""
            \(forge.executableName, privacy: .public) exit \
            \(result.exitCode, privacy: .public): \(result.stderr, privacy: .private)
            """)
            return nil
        }
        return Self.decode(stdout: result.stdout, forge: forge)
    }

    private static func arguments(for forge: ForgeKind) -> [String] {
        switch forge {
        case .gitHub:
            let fields = "number,state,isDraft,title,url,statusCheckRollup"
            return ["pr", "view", "--json", fields]
        case .gitLab:
            return ["mr", "view", "--output", "json"]
        }
    }

    /// Environment that keeps a CLI to the payload we asked for.
    ///
    /// `gh` gets its prompt disabled: it should not prompt without a
    /// pty, but a hidden prompt would hang us rather than fail, and
    /// the switch is documented. Both get their update notices
    /// silenced and `glab` its telemetry — measured on `gh` 2.94 and
    /// `glab` 1.116, all of that lands on *stderr* and so cannot
    /// reach the decoder, which reads `stdout` alone. We suppress it
    /// anyway: the split is a CLI's own choice, not a contract, and
    /// a version that moved one line to stdout would take the feature
    /// down silently. `firstJSONObject` below is the second half of
    /// that same bet.
    private static func quietEnvironment(for forge: ForgeKind) -> [String: String] {
        switch forge {
        case .gitHub:
            ["GH_PROMPT_DISABLED": "true", "GH_NO_UPDATE_NOTIFIER": "1"]
        case .gitLab:
            ["GLAB_CHECK_UPDATE": "0", "GLAB_SEND_TELEMETRY": "0"]
        }
    }

    /// Exposed for unit tests so we can exercise JSON parsing without
    /// shelling out. Keep it stable so test fixtures stay valid.
    static func decode(stdout: String, forge: ForgeKind) -> PRInfo? {
        guard let data = firstJSONObject(in: stdout) else { return nil }
        let decoder = JSONDecoder()
        do {
            switch forge {
            case .gitHub:
                return try decoder.decode(GhPayload.self, from: data).toPRInfo()
            case .gitLab:
                return try decoder.decode(GlabPayload.self, from: data).toPRInfo()
            }
        } catch {
            log.debug("""
            \(forge.executableName, privacy: .public) decode failed: \
            \(String(describing: error), privacy: .public)
            """)
            return nil
        }
    }

    /// Slice out the first complete JSON object in `raw`, ignoring
    /// whatever follows it — and whatever precedes it, as long as that
    /// carries no `{` of its own.
    ///
    /// `JSONDecoder` rejects trailing bytes, and neither CLI documents
    /// stdout as payload-only; today they keep their diagnostics on
    /// stderr, but that is a habit rather than a promise, and a
    /// version that broke it would take the feature down for a whole
    /// forge with no error to show for it. Scanning for a balanced
    /// object — tracking string and escape state so braces inside
    /// values don't confuse the depth count — makes a stray line
    /// harmless instead.
    static func firstJSONObject(in raw: String) -> Data? {
        let bytes = Array(raw.utf8)
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var depth = 0
        var isInString = false
        var isEscaped = false
        for index in start..<bytes.count {
            let byte = bytes[index]
            if isEscaped {
                isEscaped = false
                continue
            }
            if isInString {
                if byte == UInt8(ascii: #"\"#) {
                    isEscaped = true
                } else if byte == UInt8(ascii: "\"") {
                    isInString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                isInString = true
            case UInt8(ascii: "{"):
                depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    return Data(bytes[start...index])
                }
            default:
                break
            }
        }
        return nil
    }
}

// MARK: - GitHub payload

/// Mirrors the subset of `gh pr view --json …` we request. Field names
/// track `gh`'s camelCase exactly so we don't need a key-decoding
/// strategy.
private struct GhPayload: Decodable {
    let number: Int
    let state: String
    let isDraft: Bool
    let title: String
    let url: URL
    let statusCheckRollup: [GhStatusCheck]?

    func toPRInfo() -> PRInfo {
        PRInfo(
            number: number,
            state: parseState(state),
            isDraft: isDraft,
            title: title,
            url: url,
            forge: .gitHub,
            checks: aggregateChecks(statusCheckRollup)
        )
    }

    private func parseState(_ raw: String) -> PRState {
        switch raw.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
    }

    /// Collapse the per-context list into counts plus a single
    /// conclusion. Returns nil for an absent or empty rollup so the
    /// card can say "no checks" rather than "0 of 0 passed".
    private func aggregateChecks(_ list: [GhStatusCheck]?) -> PRChecks? {
        guard let list, !list.isEmpty else { return nil }
        var passed = 0
        var hasFailure = false
        var hasPending = false
        for check in list {
            switch check.normalized {
            case .success: passed += 1
            case .failure: hasFailure = true
            case .pending: hasPending = true
            }
        }
        // Failure outranks pending: a run still going does not soften
        // one that already went red.
        let conclusion: PRChecksConclusion = if hasFailure {
            .failure
        } else if hasPending {
            .pending
        } else {
            .success
        }
        return PRChecks(
            conclusion: conclusion,
            counts: PRChecks.Counts(passed: passed, total: list.count)
        )
    }
}

/// One row from `statusCheckRollup`. `gh` returns a mix of `CheckRun`
/// and `StatusContext` objects — CheckRuns expose `conclusion` +
/// `status`, StatusContexts expose `state` — so all three are decoded
/// optionally and normalized to a single tri-state, keeping the
/// aggregate above simple.
///
/// The `??` chain picks the first *present* field, which for a CheckRun
/// is always `conclusion`: `gh` marshals it as a Go string, so a run
/// still in flight arrives as `""` rather than absent. `""` normalizes
/// to `.pending`, which is the same answer `status` would have given,
/// so `status` is reached only for a shape neither forge emits today.
private struct GhStatusCheck: Decodable {
    let conclusion: String?
    let state: String?
    let status: String?

    var normalized: PRChecksConclusion {
        PRChecksConclusion(rawStatus: conclusion ?? state ?? status)
    }
}

// MARK: - GitLab payload

/// Subset of GitLab's merge-request object. `glab mr view --output
/// json` returns the API object verbatim, so we name GitLab's
/// snake_case fields and ignore everything else in the payload.
private struct GlabPayload: Decodable {
    /// GitLab exposes both a global `id` and a per-project `iid`. The
    /// UI, the web URL, and every `glab` command all use `iid`, so
    /// that is the number a user recognizes.
    let iid: Int
    let state: String
    let draft: Bool?
    let title: String
    let webURL: URL
    let headPipeline: GlabPipeline?

    enum CodingKeys: String, CodingKey {
        case iid
        case state
        case draft
        case title
        case webURL = "web_url"
        case headPipeline = "head_pipeline"
    }

    func toPRInfo() -> PRInfo {
        PRInfo(
            number: iid,
            state: parseState(state),
            isDraft: draft ?? false,
            title: title,
            url: webURL,
            forge: .gitLab,
            checks: pipelineChecks(headPipeline)
        )
    }

    /// GitLab states are `opened` / `closed` / `merged` / `locked`.
    /// `locked` means the discussion is locked, not that the request
    /// is finished, so it reads as open.
    private func parseState(_ raw: String) -> PRState {
        switch raw.lowercased() {
        case "merged": .merged
        case "closed": .closed
        default: .open
        }
    }

    /// GitLab gives one pipeline status and no per-job breakdown from
    /// the CLI, so `counts` stays nil and the card phrases the
    /// result without numbers.
    private func pipelineChecks(_ pipeline: GlabPipeline?) -> PRChecks? {
        guard let status = pipeline?.status else { return nil }
        return PRChecks(conclusion: PRChecksConclusion(rawStatus: status), counts: nil)
    }
}

private struct GlabPipeline: Decodable {
    let status: String?
}
