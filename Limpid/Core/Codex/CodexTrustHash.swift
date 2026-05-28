// CodexTrustHash.swift
// Limpid — computes the SHA-256 hash that Codex stores under
// `[hooks.state."<key>"].trusted_hash` for each enabled hook. Without
// a matching hash Codex treats the hook as untrusted and silently
// skips it, even under `--dangerously-bypass-hook-trust`.
//
// Algorithm reverse-engineered from Codex's `command_hook_hash`
// (codex-rs/hooks/src/engine/discovery.rs:command_hook_hash) and
// cross-checked against Orca's TypeScript port
// (stablyai/orca:src/main/codex/config-toml-trust.ts:computeTrustedHash).
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
    ///   - command: the exact `command` string written into the
    ///     handler in hooks.json.
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
        let handler: [String: AnyHashable] = [
            "async": isAsync,
            "command": command,
            "timeout": max(1, timeoutSec),
            "type": "command"
        ]

        var identity: [String: AnyHashable] = [
            "event_name": eventLabel,
            "hooks": [handler]
        ]
        if let matcher {
            identity["matcher"] = matcher
        }

        let canonical = canonicalize(identity)
        let serialized = serializeCanonical(canonical)
        let digest = SHA256.hash(data: Data(serialized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    /// Build the `[hooks.state."<KEY>"]` table key. Format:
    /// `<canonical_hooks_json_path>:<event_label>:<group_idx>:<handler_idx>`.
    /// `hooksJsonPath` must be canonicalized via `realpath` by the
    /// caller — Codex resolves symlinks (e.g. macOS `/var` ->
    /// `/private/var`) before building keys, and a mismatch leaves
    /// the hook in "review needed" state forever.
    static func trustKey(
        hooksJsonPath: String,
        eventLabel: String,
        groupIndex: Int = 0,
        handlerIndex: Int = 0
    ) -> String {
        "\(hooksJsonPath):\(eventLabel):\(groupIndex):\(handlerIndex)"
    }

    // MARK: - Canonical JSON

    /// Recursively sort dictionary keys. Arrays preserve order. Values
    /// are walked so nested objects also normalize.
    private static func canonicalize(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            var sorted: [(String, Any)] = []
            sorted.reserveCapacity(dict.count)
            for key in dict.keys.sorted() {
                sorted.append((key, canonicalize(dict[key] as Any)))
            }
            return sorted
        }
        if let array = value as? [Any] {
            return array.map { canonicalize($0) }
        }
        return value
    }

    /// Serialise the canonical form to compact JSON (no whitespace).
    /// We can't use `JSONSerialization` directly because it doesn't
    /// preserve key order — we already sorted in `canonicalize`, so
    /// we emit the bytes ourselves.
    private static func serializeCanonical(_ value: Any) -> String {
        if let pairs = value as? [(String, Any)] {
            let body = pairs
                .map { "\(jsonString($0.0)):\(serializeCanonical($0.1))" }
                .joined(separator: ",")
            return "{\(body)}"
        }
        if let array = value as? [Any] {
            let body = array.map { serializeCanonical($0) }.joined(separator: ",")
            return "[\(body)]"
        }
        if let s = value as? String { return jsonString(s) }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let i = value as? Int { return String(i) }
        // AnyHashable wrapper unwrap.
        if let any = value as? AnyHashable {
            if let s = any.base as? String { return jsonString(s) }
            if let b = any.base as? Bool { return b ? "true" : "false" }
            if let i = any.base as? Int { return String(i) }
            if let arr = any.base as? [AnyHashable] {
                let body = arr.map { serializeCanonical($0) }.joined(separator: ",")
                return "[\(body)]"
            }
            if let dict = any.base as? [String: AnyHashable] {
                let canonical = canonicalize(dict)
                return serializeCanonical(canonical)
            }
        }
        return "null"
    }

    /// JSON-escape a string per RFC 8259 — Codex's serialiser only
    /// needs to handle `"`, `\`, and control chars; our hook commands
    /// rarely contain anything tricky. Mirrors what Rust's `serde_json`
    /// and Orca's `JSON.stringify` would emit.
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
