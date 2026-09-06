// CodexHookInjection.swift
// Limpid — builds the `-c` flags that hand our hooks to Codex, and the
// trust block that blesses them.
//
// Both come from here because they have to agree byte for byte: Codex
// hashes each handler's definition and refuses to run one whose hash is
// not recorded. Splitting the two across types is what would let them
// drift, and the symptom is a "Hooks need review" prompt in front of the
// user rather than a silent failure.

import Foundation

enum CodexHookInjection {
    /// Codex resolves a hook supplied by CLI flags against this synthetic
    /// path rather than any file on disk, so the key half of a trust entry
    /// survives the app bundle moving. The hash half does not — it covers
    /// the command, which carries the bundle path — which is why
    /// `refresh()` runs on every launch rather than only on first install.
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
        worktreeCommand: String?
    ) -> [String] {
        var out: [String] = []
        for event in CodexHookInstaller.subscribedEvents {
            var groups = [
                group(
                    command: lifecycleCommand,
                    matcher: nil,
                    timeoutSec: event.timeoutSec
                )
            ]
            if event.jsonKey == "PreToolUse", let worktreeCommand {
                groups.append(
                    group(
                        command: worktreeCommand,
                        matcher: CodexHookInstaller.worktreeMatcher,
                        timeoutSec: event.timeoutSec
                    )
                )
            }
            out += ["-c", "hooks.\(event.jsonKey)=[\(groups.joined(separator: ","))]"]
        }
        // Codex animates its own terminal title, which bounces tab widths
        // in a sidebar that surfaces the OSC-derived title. Suppressed here
        // rather than by rewriting a config we no longer own.
        out += ["-c", "tui.terminal_title=[]"]
        return out
    }

    /// The `[hooks.state."…"]` entries covering exactly what `arguments`
    /// supplies, ready to splice into the user's config.
    static func trustBlock(lifecycleCommand: String, worktreeCommand: String?) -> String {
        var lines: [String] = []
        for event in CodexHookInstaller.subscribedEvents {
            lines += entry(
                eventLabel: event.label,
                group: 0,
                command: lifecycleCommand,
                matcher: nil,
                timeoutSec: event.timeoutSec
            )
            if event.jsonKey == "PreToolUse", let worktreeCommand {
                lines += entry(
                    eventLabel: event.label,
                    group: 1,
                    command: worktreeCommand,
                    matcher: CodexHookInstaller.worktreeMatcher,
                    timeoutSec: event.timeoutSec
                )
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Fragments

    /// One matcher group as an inline TOML table. Codex parses a `-c`
    /// value as TOML, so the shape mirrors what the file form would hold.
    private static func group(
        command: String,
        matcher: String?,
        timeoutSec: Int
    ) -> String {
        // Stated rather than defaulted: the value is hashed, and Codex's
        // default differs per event.
        let handler = "{type=\"command\",command=\(tomlString(command)),timeout=\(timeoutSec)}"
        guard let matcher else { return "{hooks=[\(handler)]}" }
        return "{matcher=\(tomlString(matcher)),hooks=[\(handler)]}"
    }

    private static func entry(
        eventLabel: String,
        group: Int,
        command: String,
        matcher: String?,
        timeoutSec: Int
    ) -> [String] {
        let hash = CodexTrustHash.compute(
            eventLabel: eventLabel,
            command: command,
            timeoutSec: timeoutSec,
            matcher: matcher
        )
        return [
            "[hooks.state.\(tomlString(trustKey(eventLabel: eventLabel, group: group)))]",
            "enabled = true",
            "trusted_hash = \(tomlString(hash))"
        ]
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
