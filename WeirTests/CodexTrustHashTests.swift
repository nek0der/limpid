// CodexTrustHashTests.swift
// Weir — verifies the SHA-256 trust hash matches Codex's
// `command_hook_hash` output. The reference vector below was
// produced via the bash spike `scripts/spike-codex-shadow.sh` with
// the exact same canonical identity:
//
//   identity = {
//     "event_name": "session_start",
//     "hooks": [{
//       "async": false,
//       "command": "/usr/bin/touch /tmp/lcx-v8.marker",
//       "timeout": 600,
//       "type": "command"
//     }]
//   }
//
// Hash captured from a Codex 0.134.0 run where the hook fired
// successfully — if this test ever breaks, the algorithm has drifted
// against upstream and CodexHookInstaller's hooks won't fire any
// more.

import Testing
@testable import Weir

@Suite("CodexTrustHash")
struct CodexTrustHashTests {
    /// One hook's identity and the hash Codex gave it.
    struct Vector: Sendable, CustomTestStringConvertible {
        let event: String
        let command: String
        var timeoutSec: Int = 600
        var matcher: String?
        let hash: String

        var testDescription: String {
            event
        }
    }

    /// The SessionStart vector is the spike's (see the header). The
    /// one-second one is Codex's own `currentHash` for the timeout
    /// `SessionEnd` and `Interrupt` default to: every other event defaults
    /// to 600, so a serializer that confused a `1` for `true` stayed
    /// invisible until those two were subscribed. The matcher one is the
    /// SHA-256 of `{"event_name":"pre_tool_use","hooks":[{"async":false,
    /// "command":"/usr/bin/touch /tmp/lcx-pretool.marker","timeout":600,
    /// "type":"command"}],"matcher":"Bash"}`, so a change to where the
    /// matcher sits in the canonical JSON shows up at once.
    @Test("compute matches Codex's own hash", arguments: [
        Vector(
            event: "session_start",
            command: "/usr/bin/touch /tmp/lcx-v8.marker",
            hash: "sha256:fd4b14127461257da7975c9cbbd34408e33f66c82bf2c4ff65c0d77fc8c01dc0"
        ),
        Vector(
            event: "session_end",
            command: "/bin/echo lifecycle",
            timeoutSec: 1,
            hash: "sha256:a293e09c0100519171de887b09b815c869812d295fea193a83d2b10c967baa81"
        ),
        Vector(
            event: "pre_tool_use",
            command: "/usr/bin/touch /tmp/lcx-pretool.marker",
            matcher: "Bash",
            hash: "sha256:ce9484197045c10817f450d469e5b53194c2133bb98c6fbafa3b87ed22c9ba71"
        )
    ])
    func referenceVector(_ vector: Vector) {
        let hash = CodexTrustHash.compute(
            eventLabel: vector.event,
            command: vector.command,
            timeoutSec: vector.timeoutSec,
            matcher: vector.matcher
        )
        #expect(hash == vector.hash)
    }

    @Test("trustKey format follows <path>:<event>:<group>:<handler>")
    func trustKeyFormat() {
        let key = CodexTrustHash.trustKey(
            sourcePath: "/private/tmp/lcx-v8.VXs3/hooks.json",
            eventLabel: "session_start"
        )
        #expect(key == "/private/tmp/lcx-v8.VXs3/hooks.json:session_start:0:0")
    }

    @Test("compute changes when command changes")
    func differentCommandDifferentHash() {
        let a = CodexTrustHash.compute(eventLabel: "stop", command: "echo a")
        let b = CodexTrustHash.compute(eventLabel: "stop", command: "echo b")
        #expect(a != b)
    }

    @Test("compute changes when event label changes")
    func differentEventDifferentHash() {
        let cmd = "echo same"
        let a = CodexTrustHash.compute(eventLabel: "stop", command: cmd)
        let b = CodexTrustHash.compute(eventLabel: "session_start", command: cmd)
        #expect(a != b)
    }

    @Test("compute includes the matcher when supplied")
    func matcherChangesHash() {
        let cmd = "echo x"
        let without = CodexTrustHash.compute(eventLabel: "pre_tool_use", command: cmd)
        let with = CodexTrustHash.compute(
            eventLabel: "pre_tool_use",
            command: cmd,
            matcher: "Bash"
        )
        #expect(without != with)
    }
}
