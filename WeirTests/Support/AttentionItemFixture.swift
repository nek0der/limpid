// AttentionItemFixture.swift
// Weir — attention items as the list holds them, for tests that need one.

import Foundation
@testable import Weir

extension AttentionItem {
    /// Claude's wait at its own prompt in `pane`, one Weir holds no
    /// approval for, as the attention list holds it.
    static func testPrompt(_ wait: PromptWait, pane: UUID) -> AttentionItem {
        testItem(id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")), kind: .prompt(wait), pane: pane)
    }

    /// A stop in `pane`, as the attention list holds it: of an exited
    /// process unless `reason` says otherwise.
    static func testStop(pane: UUID, reason: StopReason = .processExited) -> AttentionItem {
        testItem(id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")), kind: .stop(reason), pane: pane)
    }

    /// A wait at `runtime`'s prompt in `pane`, arrived now, as the window
    /// suites hand it to a decision bar. Filed under the run's stop episode,
    /// not a prompt's, as those suites have always built it; what they read
    /// is the pane and the kind, never the id.
    static func testPrompt(in pane: UUID, runtime: String = "a") -> AttentionItem {
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime(runtime), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: nil)),
            subject: .runtime(id: runtime, provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date()
        )
        return queue.items[0]
    }

    /// `runtime`'s stop at `limit` (an exited process when nil), in a pane
    /// of its own, first in the list, arrived at `arrivedAt`.
    static func testUsageLimitStop(
        _ limit: UsageLimit?,
        provider: AgentKind = .claude,
        runtime: String = "r",
        arrivedAt: Date
    ) -> AttentionItem {
        AttentionItem(
            id: .stop(EpisodeKey(origin: .runtime(runtime), episodeToken: "1")),
            kind: .stop(limit.map(StopReason.usageLimit) ?? .processExited),
            subject: .runtime(id: runtime, provider: provider, paneID: UUID(), tabID: nil, projectID: nil),
            arrivalSequence: 0,
            arrivedAt: arrivedAt
        )
    }

    /// An unread turn in `pane` that may have changed files.
    static func testUnread(pane: UUID) -> AttentionItem {
        let turn = UnreadTurn(turnID: TurnID("t"), changes: .unknown)
        return testItem(id: .unread(turn.turnID), kind: .unread(turn), pane: pane)
    }

    /// One item of each of `kinds`, in that order, as the list holds them:
    /// the `n`th of run `r<n>` of `provider`, arrived `n` seconds after the
    /// epoch, in `pane` (each in a pane of its own when `pane` is nil).
    ///
    /// Each item is filed under a stop episode of its own run, which keeps
    /// the ids apart whatever the kinds; with `filesRequestsByKey`, an
    /// approval or a question is filed under its request's key instead, as
    /// the list files one, for a test that looks a request up by it.
    static func testList(
        _ kinds: [AttentionItemKind],
        pane: UUID? = nil,
        provider: AgentKind = .claude,
        filesRequestsByKey: Bool = false
    ) -> [AttentionItem] {
        var queue = AttentionQueue()
        for (offset, kind) in kinds.enumerated() {
            let episode = AttentionItemID.stop(EpisodeKey(origin: .runtime("r\(offset)"), episodeToken: "1"))
            let id: AttentionItemID = switch kind {
            case let .approval(fact) where filesRequestsByKey, let .question(fact) where filesRequestsByKey:
                .approval(fact.key)
            default:
                episode
            }
            queue.insert(
                id: id,
                kind: kind,
                subject: .runtime(id: "r\(offset)", provider: provider, paneID: pane ?? UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        return queue.items
    }

    /// The one item of `kind` a list holds when Claude's run `r` in `pane`
    /// is all it has.
    private static func testItem(id: AttentionItemID, kind: AttentionItemKind, pane: UUID) -> AttentionItem {
        var queue = AttentionQueue()
        queue.insert(
            id: id,
            kind: kind,
            subject: .runtime(id: "r", provider: .claude, paneID: pane, tabID: nil, projectID: nil),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        return queue.items[0]
    }
}
