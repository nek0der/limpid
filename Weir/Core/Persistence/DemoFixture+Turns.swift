// DemoFixture+Turns.swift
// Weir — the turns demo mode stages for the supervision scene: four conversations, their viewed lines, and their checks.

import Foundation
import WeirDomain

extension DemoFixture {
    /// The selected workspace's Claude conversation: five turns, the first
    /// three viewed, T4 and T5 unread with changes, which the decision bar,
    /// the Needs Attention list, and the changes panel show.
    static let remindersConversation = ConversationKey(provider: .claude, conversationID: "demo-reminders", isFallback: false)
    /// The same workspace's Codex conversation: one turn with changes,
    /// unread, started between Claude's T4 and T5, so the panel's timeline
    /// shows the two conversations' turns in one list.
    static let remindersCodexConversation = ConversationKey(provider: .codex, conversationID: "demo-reminders-codex", isFallback: false)
    /// Codex's review on duesmith's main folder: two answers, the second
    /// unread.
    static let prReviewConversation = ConversationKey(provider: .codex, conversationID: "demo-pr-review", isFallback: false)
    /// The stopped Claude's: one interrupted turn, viewed, so the row's stop
    /// is its only item.
    static let webhookConversation = ConversationKey(provider: .claude, conversationID: "demo-webhook", isFallback: false)

    /// The last viewed turn of each conversation. No other agent has turns:
    /// each would add an unread answer to the list.
    static let viewedThrough: [ConversationKey: Int] = [
        remindersConversation: 3,
        prReviewConversation: 1,
        webhookConversation: 1
    ]

    /// The conversation a staged agent's pane runs, for the runtime demo
    /// mode stands in for it (`AgentProjectionAdapter.seedRuntimes`).
    static func conversation(forPane paneID: UUID) -> ConversationKey? {
        switch paneID {
        case Slot.reminders.paneID: remindersConversation
        case Slot.remindersCodex.paneID: remindersCodexConversation
        case Slot.prReview.paneID: prReviewConversation
        case Slot.webhook.paneID: webhookConversation
        default: nil
        }
    }

    /// What demo mode hands the agent projection in place of a pass.
    static var stagedProjection: StagedProjection {
        StagedProjection(turns: conversations(), conversation: conversation(forPane:), viewedThrough: viewedThrough)
    }

    /// How long ago each conversation's last turn ended, which its agent's
    /// badge says too. 20 seconds past a minute, as every badge's time is.
    static let remindersFinishedSecondsAgo = 80
    static let remindersCodexFinishedSecondsAgo = 320
    static let prReviewFinishedSecondsAgo = 860
    static let webhookStoppedSecondsAgo = 560
    /// This is when Codex's session in the selected worktree began: just before its
    /// one turn, long after Claude's, so Claude's conversation is the
    /// worktree's first and names its row.
    static let remindersCodexSessionStartedSecondsAgo = 440

    /// The prompts of those last turns, which the badges show.
    static let remindersLastPrompt = "Skip reminders for invoices that are paid or disputed"
    static let remindersCodexLastPrompt = "Add a migration for the reminder schedules table"
    static let prReviewLastPrompt = "Review PR #318 and list problems by priority"
    static let webhookLastPrompt = "Retry a payment webhook once when the receiver times out"

    /// The staged turns, as a projection pass would report them. Times are
    /// relative to now, as the badges' are, so the rows read as fresh on
    /// every launch.
    static func conversations(now: Date = Date()) -> [ConversationTurns] {
        [
            ConversationTurns(key: remindersConversation, turns: remindersTurns.compactMap {
                $0.summary(
                    in: remindersConversation,
                    pane: Slot.reminders.paneID,
                    title: conversationTitle(of: .reminders),
                    root: selectedWorktreeRoot,
                    now: now
                )
            }),
            ConversationTurns(key: remindersCodexConversation, turns: remindersCodexTurns.compactMap {
                $0.summary(
                    in: remindersCodexConversation,
                    pane: Slot.remindersCodex.paneID,
                    title: conversationTitle(of: .remindersCodex),
                    root: selectedWorktreeRoot,
                    now: now
                )
            }),
            ConversationTurns(key: prReviewConversation, turns: prReviewTurns.compactMap {
                $0.summary(
                    in: prReviewConversation,
                    pane: Slot.prReview.paneID,
                    title: conversationTitle(of: .prReview),
                    root: duesmithRoot,
                    now: now
                )
            }),
            ConversationTurns(key: webhookConversation, turns: webhookTurns.compactMap {
                $0.summary(
                    in: webhookConversation,
                    pane: Slot.webhook.paneID,
                    title: conversationTitle(of: .webhook),
                    root: folder("duesmith-fix-webhook-timeout"),
                    now: now
                )
            })
        ]
    }

    /// T1 and T2 are committed (the worktree's two commits ahead of main),
    /// T3 only answered, and T4 and T5 changed four files the worktree has
    /// not committed (`gitFacts`), which `remindersScreen` names.
    private static var remindersTurns: [StagedTurn] {
        let check = { (exitCode: Int) in
            CheckSummary(command: "pnpm test src/reminders", isFiltered: true, exitCode: exitCode)
        }
        return [
            StagedTurn(
                number: 1,
                endedSecondsAgo: 2760,
                seconds: 360,
                prompt: "Sketch the reminder schedule model",
                reply: "Added a ReminderSchedule model with the invoice, the send date, and how many reminders went out, and a factory "
                    + "for its tests.",
                changes: Changes(files: 3, added: 88, removed: 0),
                usage: TurnUsage(inputTokens: 1800, cacheWriteTokens: 21000, cacheReadTokens: 140_000, outputTokens: 4100)
            ),
            StagedTurn(
                number: 2,
                endedSecondsAgo: 1920,
                seconds: 540,
                prompt: "Add a job that finds overdue invoices",
                reply: "The job runs every hour and queues one reminder per overdue invoice. The first test run failed on a time zone; "
                    + "it passes now.",
                changes: Changes(files: 3, added: 121, removed: 8),
                check: CheckSummary(command: "pnpm test src/jobs", isFiltered: true, exitCode: 0),
                earlierChecks: [1],
                usage: TurnUsage(inputTokens: 3100, cacheWriteTokens: 38000, cacheReadTokens: 410_000, outputTokens: 7200)
            ),
            StagedTurn(
                number: 3,
                endedSecondsAgo: 1500,
                seconds: 120,
                prompt: "How does the mailer handle bounced emails?",
                reply: "The mail provider reports a bounce through a webhook, and the mailer then marks the contact unreachable and "
                    + "sends it no more reminders.",
                changes: nil,
                usage: TurnUsage(inputTokens: 900, cacheWriteTokens: 6000, cacheReadTokens: 90000, outputTokens: 1200)
            ),
            StagedTurn(
                number: 4,
                endedSecondsAgo: 478,
                seconds: 662,
                prompt: "Show the reminder settings on the billing page",
                reply: "The settings save, but a paid invoice still gets a reminder, so two tests fail. I'll fix that in the next turn.",
                changes: Changes(files: 2, added: 47, removed: 9),
                check: check(1),
                earlierChecks: [1],
                usage: TurnUsage(inputTokens: 4200, cacheWriteTokens: 61000, cacheReadTokens: 1_200_000, outputTokens: 9800)
            ),
            StagedTurn(
                number: 5,
                endedSecondsAgo: remindersFinishedSecondsAgo,
                seconds: 330,
                prompt: remindersLastPrompt,
                reply: "Reminders now go only to invoices that are still open past their due date. Paid, voided, and disputed invoices "
                    + "are skipped, and a payment that arrives after the job starts cancels the reminder before it is sent. INV-1042 "
                    + "($1,240.00, 14 days overdue) gets one; INV-1043, paid this morning, does not. The two tests that failed last "
                    + "turn pass, and three new ones cover partial payments.",
                changes: Changes(files: 2, added: 89, removed: 4),
                check: check(0),
                earlierChecks: [1, 1],
                usage: TurnUsage(inputTokens: 3000, cacheWriteTokens: 75000, cacheReadTokens: 2_100_000, outputTokens: 6200)
            )
        ]
    }

    /// Codex's one turn in the selected worktree: the migration, started
    /// after Claude's T4 ended and before T5 began, so the timeline
    /// reads T4, Codex's T1, T5. Its file is the worktree's fifth
    /// uncommitted one (`gitFacts`).
    private static var remindersCodexTurns: [StagedTurn] {
        [
            StagedTurn(
                number: 1,
                endedSecondsAgo: remindersCodexFinishedSecondsAgo,
                seconds: 95,
                prompt: remindersCodexLastPrompt,
                reply: "The migration creates reminder_schedules with the invoice, the send date, and a unique key on both, so a "
                    + "schedule is written once per invoice. Run pnpm migrate to apply it.",
                changes: Changes(files: 1, added: 24, removed: 0),
                usage: TurnUsage(inputTokens: 1649, cacheWriteTokens: 0, cacheReadTokens: 94464, outputTokens: 807)
            )
        ]
    }

    /// What the selected worktree's turns changed altogether, as the
    /// panel's one comparison counts it (`WorktreeChanges.Git.inert`):
    /// every staged turn's files, none shared, their lines added up.
    static var worktreeCounts: ChangeSummary {
        .changed(files: 11, added: 369, removed: 21)
    }

    private static var prReviewTurns: [StagedTurn] {
        [
            StagedTurn(
                number: 1,
                endedSecondsAgo: 1770,
                seconds: 90,
                prompt: "Summarize what PR #318 changes",
                reply: "It moves credit notes onto invoices and formats money per account.",
                changes: nil
            ),
            StagedTurn(
                number: 2,
                endedSecondsAgo: prReviewFinishedSecondsAgo,
                seconds: 250,
                prompt: prReviewLastPrompt,
                reply: "Three problems, most serious first: Major: reopening an invoice applies its credit note twice. applyCredits "
                    + "runs again on reopen and does not check whether the credit was already applied. · Minor: formatMoney ignores "
                    + "the account's currency setting. · Nit: two tests in invoices.test.ts share a name.",
                changes: nil
            )
        ]
    }

    /// Interrupted by the error that stopped the agent, with what it had
    /// changed by then, which "Show Partial Changes" opens.
    private static var webhookTurns: [StagedTurn] {
        [
            StagedTurn(
                number: 1,
                endedSecondsAgo: webhookStoppedSecondsAgo,
                seconds: 250,
                prompt: webhookLastPrompt,
                changes: Changes(files: 2, added: 18, removed: 3),
                phase: .interrupted
            )
        ]
    }

    /// What a staged turn changed.
    private struct Changes {
        let files: Int
        let added: Int
        let removed: Int
    }

    /// One staged turn: what it was asked and what the agent replied, when
    /// it ended and how long it ran, what it changed (nothing for an
    /// answer), the check it ran last and how the ones before it exited, and
    /// the tokens it used. The reply is its first paragraph, as the record
    /// keeps it (`reply_head`), in the words the pane's output ends on;
    /// `nil` for a turn no stop ended.
    private struct StagedTurn {
        let number: Int
        let endedSecondsAgo: Int
        let seconds: Int
        let prompt: String
        var reply: String?
        let changes: Changes?
        var check: CheckSummary?
        var earlierChecks: [Int] = []
        var usage: TurnUsage?
        var phase: TurnPhase = .finished

        /// Read through the same decoder a pass's turns go through, so the
        /// scene shows what a real turn would. `title` is the conversation's,
        /// as the hook records it on each turn once the provider has named
        /// the conversation, which it has by every staged turn's end.
        func summary(in conversation: ConversationKey, pane paneID: UUID, title: String?, root: URL, now: Date) -> TurnSummary? {
            let format = ISO8601DateFormatter()
            let finished = now.addingTimeInterval(TimeInterval(-endedSecondsAgo))
            let started = finished.addingTimeInterval(TimeInterval(-seconds))
            let changed: [String: Any] = changes.map {
                ["kind": "changed", "files": $0.files, "added": $0.added, "removed": $0.removed, "hasBashChanges": false]
            } ?? ["kind": "unchanged"]
            let tree = { (end: Int) in Self.tree(conversation, number * 2 - 1 + end) }
            var fields: [String: Any] = [
                "turnId": "\(conversation.conversationID)-T\(number)",
                "conversation": [
                    "provider": conversation.provider.rawValue,
                    "conversationId": conversation.conversationID,
                    "isFallback": false
                ],
                // The runtime demo mode stands in for the agent is named by
                // its pane (`seedRuntimes`).
                "runId": paneID.uuidString,
                "paneId": paneID.uuidString,
                "displayNumber": number,
                "startedAt": format.string(from: started),
                "finishedAt": format.string(from: finished),
                "durationSeconds": seconds,
                "phase": phase.rawValue,
                "hasPrompt": true,
                "promptHead": prompt,
                "changes": changed,
                "begin": ["kind": "captured", "tree": tree(0), "root": root.path],
                "end": ["kind": "captured", "tree": tree(1), "root": root.path]
            ]
            if let check {
                var lastCheck: [String: Any] = ["command": check.command, "isFiltered": check.isFiltered]
                if let exitCode = check.exitCode {
                    lastCheck["exitCode"] = exitCode
                }
                fields["lastCheck"] = lastCheck
                let exits: [Int?] = earlierChecks + [check.exitCode]
                fields["checks"] = exits.map { exit -> [String: Any] in
                    var mark: [String: Any] = ["isFiltered": check.isFiltered]
                    mark["exitCode"] = exit
                    return mark
                }
                fields["checkCount"] = exits.count
            }
            if let reply {
                fields["replyHead"] = reply
            }
            if let title {
                fields["conversationTitle"] = title
            }
            if let usage {
                fields["usage"] = [
                    "inputTokens": usage.inputTokens,
                    "cacheWriteTokens": usage.cacheWriteTokens,
                    "cacheReadTokens": usage.cacheReadTokens,
                    "outputTokens": usage.outputTokens
                ]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: fields) else { return nil }
            return try? JSONDecoder().decode(TurnSummary.self, from: data)
        }

        /// A tree name Git could have written, 40 hex digits, distinct across
        /// the conversations; never read, as demo mode asks Git nothing.
        private static func tree(_ conversation: ConversationKey, _ number: Int) -> String {
            let prefix = switch conversation {
            case DemoFixture.remindersConversation: "a"
            case DemoFixture.prReviewConversation: "b"
            case DemoFixture.remindersCodexConversation: "e"
            default: "c"
            }
            let suffix = String(number)
            return prefix + String(repeating: "d", count: 39 - suffix.count) + suffix
        }
    }
}
