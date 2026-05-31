// BootstrapItem.swift
// Limpid — Shape for the per-project `bootstrap` array: each item is a
// shell command Limpid runs inside a freshly-created worktree right
// after `git worktree add`. Items can be a bare string (shorthand) or
// a detailed object, so future knobs (timeout, cwd, retries) land
// without breaking older `state.json` files.

import Foundation

/// One bootstrap step for a freshly-created worktree.
///
/// JSON shape mirrors the public schema's `oneOf`:
///   - `"pnpm install"` (bare string — shorthand for default options)
///   - `{ "cmd": "make ghostty", "timeout": 1800 }` (detailed object)
enum BootstrapItem: Codable, Equatable {
    case shorthand(String)
    case detailed(BootstrapDetail)

    /// Command line we hand to `sh -c`.
    var cmd: String {
        switch self {
        case let .shorthand(s): s
        case let .detailed(d): d.cmd
        }
    }

    /// Effective timeout in seconds. Always returns a concrete value so
    /// callers don't need to know about the shorthand vs detailed split.
    var timeout: Int {
        switch self {
        case .shorthand:
            BootstrapDetail.defaultTimeoutSeconds
        case let .detailed(d):
            d.timeout ?? BootstrapDetail.defaultTimeoutSeconds
        }
    }

    /// Working directory relative to the new worktree root, or nil
    /// when the command should run in the worktree root itself.
    var cwd: String? {
        switch self {
        case .shorthand: nil
        case let .detailed(d): d.cwd
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self) {
            self = .shorthand(s)
            return
        }
        let detailed = try container.decode(BootstrapDetail.self)
        self = .detailed(detailed)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .shorthand(s):
            try container.encode(s)
        case let .detailed(d):
            try container.encode(d)
        }
    }
}

struct BootstrapDetail: Codable, Equatable {
    /// Aligns with Claude Code's 600s PreToolUse hook ceiling — the
    /// number `timeout`-aware code paths should clamp to once they exist.
    ///
    /// NOT enforced yet. v1 ships the schema slot so users can hand-edit
    /// `state.json` for the future, but neither
    /// `WindowSession.runBootstrapStep` nor the shell hook honor the
    /// value — a step that never exits stays alive until the process
    /// goes away. A follow-up PR will wire `Task.sleep` +
    /// `Process.terminate()` on the Swift side and `gtimeout` (or
    /// equivalent) on the shell side.
    static let defaultTimeoutSeconds = 600

    var cmd: String
    /// Seconds. Reserved for v2 — see `defaultTimeoutSeconds` above.
    var timeout: Int?
    var cwd: String?

    init(cmd: String, timeout: Int? = nil, cwd: String? = nil) {
        self.cmd = cmd
        self.timeout = timeout
        self.cwd = cwd
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.cmd = try c.decode(String.self, forKey: .cmd)
        self.timeout = try c.decodeIfPresent(Int.self, forKey: .timeout)
        self.cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
    }
}
