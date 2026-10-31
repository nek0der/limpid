// CodexHookInjection.swift
// Weir — builds the `-c` flags that hand our hooks to Codex, together
// with the trust that blesses them.
//
// Both come from one list of handlers because they have to agree byte for
// byte: Codex hashes each handler's definition and refuses to run one whose
// hash is not recorded. Splitting the two would let them drift, and the
// symptom is a "Hooks need review" prompt in front of the user rather than
// a silent failure.

import Foundation
import OSLog

private let log = Logger.weir("codex.hooks")

enum CodexHookInjection {
    /// One hook event we ask Codex to call us on.
    struct SubscribedEvent: Decodable, Sendable {
        /// Our own name for the event. Doubles as the group segment of the
        /// trust key, so changing it invalidates that entry.
        let label: String
        /// The name Codex uses, both as the `hooks.<key>` table and as the
        /// payload's `hook_event_name`.
        let jsonKey: String
        /// Part of the identity Codex hashes, so it has to be stated
        /// rather than left to a default: measured 2026-09, the two events
        /// that end a session or a turn abruptly default to one second
        /// while every other event defaults to 600, and `SessionEnd`
        /// refuses anything above three. Hashing all of them at 600 left
        /// those two permanently `modified`, which is to say never run.
        let timeoutSec: Int
    }

    /// What the Codex crate's install recipe says to hand Codex.
    private struct Subscription: Decodable {
        var events: [SubscribedEvent] = []
        var worktreeMatcher = ""
    }

    /// Read once from the crate, which owns the list. Empty when the recipe
    /// cannot be read: no hooks are handed to Codex, the same "decide nothing"
    /// an empty registry gives, rather than a list that could disagree.
    private static let subscription: Subscription = {
        let fragment = AgentProviderRegistry.recipes["codex"]?.settingsFragments
            .first { $0.target == "codex.hooks" }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = fragment?.body.data(using: .utf8),
              let subscription = try? decoder.decode(Subscription.self, from: body)
        else {
            log.error("Codex hook subscription unavailable")
            return Subscription()
        }
        return subscription
    }()

    /// Hook events we subscribe to.
    static var subscribedEvents: [SubscribedEvent] {
        subscription.events
    }

    /// Codex evaluates the handler's `matcher` field as a regex (Claude
    /// uses a flat string equal-match). The crate's `^Bash$` pins the worktree
    /// intercept to the exact Bash tool the way Claude's
    /// `settings.template.json` does with `"matcher": "Bash"`.
    static var worktreeMatcher: String {
        subscription.worktreeMatcher
    }

    // MARK: - Flags

    /// Codex resolves a hook supplied by CLI flags against this synthetic
    /// path rather than any file on disk, so the key half of a trust entry
    /// survives the app bundle moving. The hash half does not: it covers
    /// the command, which carries the bundle path, so both are built again
    /// for every pane.
    private static let sessionFlagsPath = "/<session-flags>/config.toml"

    static func trustKey(eventLabel: String, group: Int) -> String {
        CodexTrustHash.trustKey(
            sourcePath: sessionFlagsPath,
            eventLabel: eventLabel,
            groupIndex: group
        )
    }

    /// Flags for `codex`, already split into `-c` / value pairs.
    static func arguments(
        lifecycleCommand: String,
        worktreeCommand: String?,
        approvalCommand: String? = nil
    ) -> [String] {
        let handlers = Self.handlers(
            lifecycleCommand: lifecycleCommand,
            worktreeCommand: worktreeCommand,
            approvalCommand: approvalCommand
        )
        var out: [String] = []
        for event in subscribedEvents {
            let groups = handlers.filter { $0.event.jsonKey == event.jsonKey }.map(\.group)
            out += ["-c", "hooks.\(event.jsonKey)=[\(groups.joined(separator: ","))]"]
        }
        // Codex reads trust from the flags as well as from the user's own
        // config, so the hooks need no record in `~/.codex/config.toml`, and
        // a Codex whose `CODEX_HOME` is elsewhere runs them too. One inline
        // table, because Codex splits a flag's key at each dot, and our keys
        // hold one (`config.toml`): `hooks.state."<key>".trusted_hash=…` names
        // some other key, and the hook stays untrusted.
        out += ["-c", "hooks.state={\(handlers.map(\.trustEntry).joined(separator: ","))}"]
        // Codex animates its own terminal title, which bounces tab widths
        // in a sidebar that surfaces the OSC-derived title. Suppressed here
        // rather than by rewriting a config we do not own.
        out += ["-c", "tui.terminal_title=[]"]
        // Codex's TUI posts its own desktop notifications (OSC 9 or BEL,
        // "Approval requested: …", "Agent turn complete") for the same
        // moments Weir notifies about, so a person saw each twice, the
        // TUI's in English. `tui.notifications` takes `false` or a list of
        // kinds (read off the installed codex-cli 0.163.0 binary, whose
        // `TuiNotificationSettings` names the key; an older Codex ignores
        // a key it does not know). Off here, for this launch only, as the
        // title is, leaving the user's config as it is. Claude's template
        // does the same with `preferredNotifChannel`.
        out += ["-c", "tui.notifications=false"]
        return out
    }

    // MARK: - Handlers

    /// One handler we pass: the matcher group that defines it and the
    /// trust entry that covers it, both from the same values.
    private struct Handler {
        let event: SubscribedEvent
        let groupIndex: Int
        let command: String
        let matcher: String?

        /// The matcher group as an inline TOML table. Codex parses a `-c`
        /// value as TOML, so the shape mirrors what the file form would hold.
        var group: String {
            // Stated rather than defaulted: the value is hashed, and Codex's
            // default differs per event.
            let handler = "{type=\"command\",command=\(CodexHookInjection.tomlString(command)),timeout=\(event.timeoutSec)}"
            guard let matcher else { return "{hooks=[\(handler)]}" }
            return "{matcher=\(CodexHookInjection.tomlString(matcher)),hooks=[\(handler)]}"
        }

        /// `"<key>"={enabled=true,trusted_hash="…"}`, one entry of the
        /// `hooks.state` inline table.
        var trustEntry: String {
            let hash = CodexTrustHash.compute(
                eventLabel: event.label,
                command: command,
                timeoutSec: event.timeoutSec,
                matcher: matcher
            )
            let key = CodexHookInjection.trustKey(eventLabel: event.label, group: groupIndex)
            return "\(CodexHookInjection.tomlString(key))={enabled=true,trusted_hash=\(CodexHookInjection.tomlString(hash))}"
        }
    }

    private static func handlers(
        lifecycleCommand: String,
        worktreeCommand: String?,
        approvalCommand: String?
    ) -> [Handler] {
        subscribedEvents.flatMap { event -> [Handler] in
            var out = [
                Handler(
                    event: event,
                    groupIndex: 0,
                    command: event.jsonKey == "PermissionRequest"
                        ? approvalCommand ?? lifecycleCommand
                        : lifecycleCommand,
                    matcher: nil
                )
            ]
            if event.jsonKey == "PreToolUse", let worktreeCommand {
                out.append(
                    Handler(
                        event: event,
                        groupIndex: 1,
                        command: worktreeCommand,
                        matcher: CodexHookInjection.worktreeMatcher
                    )
                )
            }
            return out
        }
    }

    /// TOML basic string. Bundle paths carry neither quotes nor
    /// backslashes today, but a hook whose command was mangled into a
    /// second argument would be worse than one that fails to parse.
    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

extension CodexHookInjection.SubscribedEvent {
    /// The crate's names for these fields, once the decoder has converted them
    /// from snake case.
    private enum CodingKeys: String, CodingKey {
        case label
        case jsonKey = "event"
        case timeoutSec = "timeoutSeconds"
    }
}
