// CodexHookInjectionTests.swift
// Weir — the `-c` flags handed to Codex and the trust that blesses them
// come from one list of handlers because they have to agree exactly. A hash that
// does not match the command it is supposed to cover puts the receiver in
// Codex's "Hooks need review" prompt, which is the one failure of this
// design a user would actually see.

import Foundation
import Testing
@testable import Weir

@Suite("CodexHookInjection")
struct CodexHookInjectionTests {
    private let lifecycle = "/bin/sh '/x/weir-hook'"
    private let worktree = "/bin/sh '/x/weir-pretool-worktree-hook'"
    private let approval = "'/x/AgentIntegrationHookHelper' permission-request codex"

    @Test("routes only PermissionRequest through the signed helper")
    func arguments_permissionRequestUsesApprovalHelper() throws {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle,
            worktreeCommand: worktree,
            approvalCommand: approval
        )

        let permission = try #require(args.first { $0.hasPrefix("hooks.PermissionRequest=") })
        let preToolUse = try #require(args.first { $0.hasPrefix("hooks.PreToolUse=") })
        #expect(permission.contains(approval))
        #expect(!permission.contains(lifecycle))
        #expect(preToolUse.contains(lifecycle))
        #expect(!preToolUse.contains(approval))
    }

    @Test("emits one -c flag per subscribed event, plus trust and the title suppression")
    func arguments_coverEverySubscribedEvent() {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: nil
        )
        for event in CodexHookInjection.subscribedEvents {
            #expect(
                args.contains { $0.hasPrefix("hooks.\(event.jsonKey)=") },
                "no -c fragment for \(event.jsonKey)"
            )
        }
        #expect(args.contains { $0.hasPrefix("hooks.state={") })
        #expect(args.contains("tui.terminal_title=[]"))
        // Codex's own notifications would double Weir's.
        #expect(args.contains("tui.notifications=false"))
        // Every value is preceded by its own `-c`.
        #expect(args.count(where: { $0 == "-c" }) == args.count / 2)
    }

    @Test("gives PreToolUse a second, matched group when the worktree hook exists")
    func arguments_worktreeHook_addsMatchedGroup() throws {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: worktree
        )
        let preToolUse = try #require(args.first { $0.hasPrefix("hooks.PreToolUse=") })
        #expect(preToolUse.contains(CodexHookInjection.worktreeMatcher))
        #expect(preToolUse.contains(worktree))
    }

    @Test("omits the second group when there is no worktree hook")
    func arguments_noWorktreeHook_singleGroup() {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: nil
        )
        let preToolUse = args.first { $0.hasPrefix("hooks.PreToolUse=") }
        #expect(preToolUse?.contains(CodexHookInjection.worktreeMatcher) == false)
    }

    /// The invariant the whole design rests on: every hash in the flags is
    /// the hash of the command actually being passed, at the group index it
    /// is actually passed at.
    @Test("every trust entry matches the command the flags supply")
    func trust_hashesMatchTheArguments() throws {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle,
            worktreeCommand: worktree,
            approvalCommand: approval
        )
        let state = try #require(args.first { $0.hasPrefix("hooks.state={") })
        for event in CodexHookInjection.subscribedEvents {
            let expected = CodexTrustHash.compute(
                eventLabel: event.label,
                command: event.jsonKey == "PermissionRequest" ? approval : lifecycle,
                timeoutSec: event.timeoutSec
            )
            let key = CodexHookInjection.trustKey(eventLabel: event.label, group: 0)
            #expect(
                state.contains("\"\(key)\"={enabled=true,trusted_hash=\"\(expected)\"}"),
                "no trust for \(event.label)"
            )
        }
        let worktreeHash = CodexTrustHash.compute(
            eventLabel: "pre_tool_use",
            command: worktree,
            timeoutSec: 600,
            matcher: CodexHookInjection.worktreeMatcher
        )
        let worktreeKey = CodexHookInjection.trustKey(eventLabel: "pre_tool_use", group: 1)
        #expect(state.contains("\"\(worktreeKey)\"={enabled=true,trusted_hash=\"\(worktreeHash)\"}"))
    }

    /// Codex splits a flag's key at each dot, and a trust key holds one, so
    /// the entries have to sit in one inline table. The shim also splits
    /// the flags at line feeds.
    @Test("passes trust as one single-line inline table")
    func trust_isOneInlineTable() {
        let args = CodexHookInjection.arguments(lifecycleCommand: lifecycle, worktreeCommand: worktree)
        #expect(args.count(where: { $0.hasPrefix("hooks.state") }) == 1)
        #expect(!args.contains { $0.hasPrefix("hooks.state.") })
        #expect(!args.contains { $0.contains("\n") })
    }

    /// Codex resolves session-flag hooks against a synthetic path, not the
    /// receiver's own, so the key never changes when the bundle moves.
    @Test("keys the trust entries on the session-flags path")
    func trustKey_usesTheSyntheticPath() {
        #expect(
            CodexHookInjection.trustKey(eventLabel: "stop", group: 0)
                == "/<session-flags>/config.toml:stop:0:0"
        )
    }
}
