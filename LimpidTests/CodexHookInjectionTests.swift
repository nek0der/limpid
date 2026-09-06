// CodexHookInjectionTests.swift
// Limpid — the `-c` flags handed to Codex and the trust block that blesses
// them come from one place because they have to agree exactly. A hash that
// does not match the command it is supposed to cover puts the receiver in
// Codex's "Hooks need review" prompt, which is the one failure of this
// design a user would actually see.

import Foundation
import Testing
@testable import Limpid

@Suite("CodexHookInjection")
struct CodexHookInjectionTests {
    private let lifecycle = "/bin/sh '/x/limpid-hook'"
    private let worktree = "/bin/sh '/x/limpid-pretool-worktree-hook'"

    @Test("emits one -c flag per subscribed event, plus the title suppression")
    func arguments_coverEverySubscribedEvent() {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: nil
        )
        for event in CodexHookInstaller.subscribedEvents {
            #expect(
                args.contains { $0.hasPrefix("hooks.\(event.jsonKey)=") },
                "no -c fragment for \(event.jsonKey)"
            )
        }
        #expect(args.contains("tui.terminal_title=[]"))
        // Every value is preceded by its own `-c`.
        #expect(args.count(where: { $0 == "-c" }) == args.count / 2)
    }

    @Test("gives PreToolUse a second, matched group when the worktree hook exists")
    func arguments_worktreeHook_addsMatchedGroup() {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: worktree
        )
        let preToolUse = try? #require(args.first { $0.hasPrefix("hooks.PreToolUse=") })
        #expect(preToolUse?.contains(CodexHookInstaller.worktreeMatcher) == true)
        #expect(preToolUse?.contains(worktree) == true)
    }

    @Test("omits the second group when there is no worktree hook")
    func arguments_noWorktreeHook_singleGroup() {
        let args = CodexHookInjection.arguments(
            lifecycleCommand: lifecycle, worktreeCommand: nil
        )
        let preToolUse = args.first { $0.hasPrefix("hooks.PreToolUse=") }
        #expect(preToolUse?.contains(CodexHookInstaller.worktreeMatcher) == false)
    }

    /// The invariant the whole design rests on: every hash in the block is
    /// the hash of the command actually being passed, at the group index it
    /// is actually passed at.
    @Test("every trust entry matches the command the flags supply")
    func trustBlock_hashesMatchTheArguments() {
        let block = CodexHookInjection.trustBlock(
            lifecycleCommand: lifecycle, worktreeCommand: worktree
        )
        for event in CodexHookInstaller.subscribedEvents {
            let expected = CodexTrustHash.compute(
                eventLabel: event.label,
                command: lifecycle,
                timeoutSec: event.timeoutSec
            )
            #expect(block.contains(expected), "no hash for \(event.label)")
            #expect(
                block.contains(
                    CodexHookInjection.trustKey(eventLabel: event.label, group: 0)
                )
            )
        }
        let worktreeHash = CodexTrustHash.compute(
            eventLabel: "pre_tool_use",
            command: worktree,
            timeoutSec: 600,
            matcher: CodexHookInstaller.worktreeMatcher
        )
        #expect(block.contains(worktreeHash))
        #expect(
            block.contains(
                CodexHookInjection.trustKey(eventLabel: "pre_tool_use", group: 1)
            )
        )
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
