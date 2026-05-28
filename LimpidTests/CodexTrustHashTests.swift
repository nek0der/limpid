// CodexTrustHashTests.swift
// Limpid — verifies the SHA-256 trust hash matches Codex's
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
// against upstream and CodexHomeRedirector's hooks won't fire any
// more.

import Testing
@testable import Limpid

@Suite("CodexTrustHash")
struct CodexTrustHashTests {
    @Test("compute matches the spike reference vector for SessionStart")
    func referenceVector() {
        let hash = CodexTrustHash.compute(
            eventLabel: "session_start",
            command: "/usr/bin/touch /tmp/lcx-v8.marker"
        )
        #expect(
            hash == "sha256:fd4b14127461257da7975c9cbbd34408e33f66c82bf2c4ff65c0d77fc8c01dc0"
        )
    }

    @Test("trustKey format follows <path>:<event>:<group>:<handler>")
    func trustKeyFormat() {
        let key = CodexTrustHash.trustKey(
            hooksJsonPath: "/private/tmp/lcx-v8.VXs3/hooks.json",
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

    /// Second reference vector covering the matcher branch (so an
    /// upstream change to either matcher placement or its
    /// alphabetical position in the canonical JSON shows up
    /// immediately). Like the SessionStart vector this hash is the
    /// SHA-256 of:
    ///   {"event_name":"pre_tool_use","hooks":[{"async":false,"command":"/usr/bin/touch
    /// /tmp/lcx-pretool.marker","timeout":600,"type":"command"}],"matcher":"Bash"}
    @Test("compute matches reference vector for pre_tool_use + matcher=Bash")
    func referenceVectorWithMatcher() {
        let hash = CodexTrustHash.compute(
            eventLabel: "pre_tool_use",
            command: "/usr/bin/touch /tmp/lcx-pretool.marker",
            matcher: "Bash"
        )
        #expect(
            hash == "sha256:ce9484197045c10817f450d469e5b53194c2133bb98c6fbafa3b87ed22c9ba71"
        )
    }
}
