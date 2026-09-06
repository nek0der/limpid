// CodexTrustHash.swift
// Limpid — computes the SHA-256 hash that Codex stores under
// `[hooks.state."<key>"].trusted_hash` for each enabled hook. Without
// a matching hash Codex treats the hook as untrusted and silently
// skips it, even under `--dangerously-bypass-hook-trust`.
//
// Algorithm reverse-engineered from Codex's `command_hook_hash`
// (codex-rs/hooks/src/engine/discovery.rs:command_hook_hash).
//
// Identity shape (object keys sorted alphabetically before encoding):
//   {
//     "event_name": "<snake_case>",
//     "hooks": [
//       { "async": <bool>, "command": "<str>", "timeout": <int>, "type": "command" }
//     ],
//     "matcher": "<str>"      // omitted when no matcher
//   }
// Serialization: JSON with `separators=(',', ':')` style (no spaces).
// Output: `sha256:<hex>`.

import CryptoKit
import Foundation

enum CodexTrustHash {
    /// Compute the `trusted_hash` value for a single hook handler.
    ///
    /// - Parameters:
    ///   - eventLabel: snake_case event id (`session_start`,
    ///     `user_prompt_submit`, `pre_tool_use`, `stop`, etc.). Must
    ///     match the label codex builds internally — see
    ///     `hook_event_key_label` in codex-rs/hooks/src/lib.rs.
    ///   - command: the exact `command` string of the handler
    ///     definition, wherever it came from.
    ///   - timeoutSec: handler timeout. Defaults to 600 (codex's
    ///     default); explicit values are clamped to a minimum of 1.
    ///   - isAsync: handler's `async` flag. Defaults to false.
    ///   - matcher: optional matcher pattern (only meaningful for
    ///     PreToolUse / PostToolUse). `nil` to omit.
    static func compute(
        eventLabel: String,
        command: String,
        timeoutSec: Int = 600,
        isAsync: Bool = false,
        matcher: String? = nil
    ) -> String {
        let handler: Canonical = .object([
            "async": .bool(isAsync),
            "command": .string(command),
            "timeout": .int(max(1, timeoutSec)),
            "type": .string("command")
        ])
        var identity: [String: Canonical] = [
            "event_name": .string(eventLabel),
            "hooks": .array([handler])
        ]
        if let matcher {
            identity["matcher"] = .string(matcher)
        }
        let digest = SHA256.hash(data: Data(Canonical.object(identity).serialized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Build the `[hooks.state."<KEY>"]` table key. Format:
    /// `<source_path>:<event_label>:<group_idx>:<handler_idx>`.
    ///
    /// A `sourcePath` naming a real file must be canonicalized via
    /// `realpath` by the caller — Codex resolves symlinks (e.g. macOS
    /// `/var` → `/private/var`) before building keys, and a mismatch
    /// leaves the hook in "review needed" state forever. A hook supplied
    /// by CLI flags has no file behind it and uses the synthetic path in
    /// `CodexHookInjection` verbatim instead.
    static func trustKey(
        sourcePath: String,
        eventLabel: String,
        groupIndex: Int = 0,
        handlerIndex: Int = 0
    ) -> String {
        "\(sourcePath):\(eventLabel):\(groupIndex):\(handlerIndex)"
    }

    // MARK: - Canonical JSON

    /// The value model the identity is built from.
    ///
    /// Modelling it explicitly rather than with `Any` / `AnyHashable` is
    /// the whole point: a bridged `1` answers `as? Bool` on Darwin, so the
    /// previous serializer emitted `true` for a one-second timeout and the
    /// hash silently stopped matching Codex's. Only `SessionEnd` and
    /// `Interrupt` default to one second, which is why it stayed hidden.
    private indirect enum Canonical {
        case string(String)
        case int(Int)
        case bool(Bool)
        case array([Canonical])
        case object([String: Canonical])

        /// Compact JSON with object keys sorted, matching what Codex
        /// hashes. `JSONSerialization` cannot be used because it does not
        /// preserve key order.
        var serialized: String {
            switch self {
            case let .string(value):
                jsonString(value)
            case let .int(value):
                String(value)
            case let .bool(value):
                value ? "true" : "false"
            case let .array(values):
                "[" + values.map(\.serialized).joined(separator: ",") + "]"
            case let .object(values):
                "{" + values.keys.sorted()
                    .compactMap { key in
                        values[key].map { "\(jsonString(key)):\($0.serialized)" }
                    }
                    .joined(separator: ",") + "}"
            }
        }
    }

    /// JSON-escape a string per RFC 8259 — Codex's serializer only
    /// needs to handle `"`, `\`, and control chars; our hook commands
    /// rarely contain anything tricky. Mirrors what Rust's `serde_json`
    /// would emit (compact JSON, no extraneous spaces).
    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for char in s.unicodeScalars {
            switch char {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if char.value < 0x20 {
                    out += String(format: "\\u%04x", char.value)
                } else {
                    out.unicodeScalars.append(char)
                }
            }
        }
        out += "\""
        return out
    }
}
