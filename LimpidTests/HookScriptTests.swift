// HookScriptTests.swift
// Limpid — runs each agent's `limpid-hook` wrapper, and through it the Hook
// Helper, against the payloads that agent sends: the pid resolution, the
// event mapping, the prompt snapshot, and the files the app reads by name.

import Foundation
import Testing
@testable import Limpid

@Suite(
    "Hook receiver",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(2))
)
struct HookScriptTests {
    private func runHooks(
        _ agent: HookAgent,
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:],
        wrapper: URL? = nil,
        afterEach: ((URL, URL, String, Int) throws -> Void)? = nil,
        prepare: ((URL, URL, String) throws -> Void)? = nil
    ) throws -> [String: Any]? {
        try HookScriptHarness.runHooks(
            agent, payloads, extraEnvironment: extraEnvironment, wrapper: wrapper, afterEach: afterEach, prepare: prepare
        )
    }

    private func optionalText(_ record: [String: Any], _ key: String) -> String? {
        HookScriptHarness.optionalText(record, key)
    }

    // MARK: - Prompt snapshot

    @Test("captures an exact private prompt snapshot without changing the real index", arguments: HookAgent.allCases)
    func promptSnapshot_isPrivateAndSessionEndCleansIt(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        try Data("before prompt\n".utf8).write(to: repo.url.appendingPathComponent("pending.txt"))
        let status = try await repo.git(["status", "--porcelain"])
        let expectedRoot = try await repo.git(["rev-parse", "--show-toplevel"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTree = try scratchTree(in: repo.url)
        let indexURL = repo.url.appendingPathComponent(".git/index")
        let indexMTime = try #require(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date
        )
        var baseTree = ""
        _ = try runHooks(
            agent,
            [
                agent.payload("UserPromptSubmit", extra: ["cwd": repo.url.path]),
                agent.payload("Stop", extra: ["cwd": repo.url.path]),
                agent.payload("SessionEnd", extra: ["cwd": repo.url.path, "reason": "other"])
            ],
            afterEach: { _, states, paneID, eventIndex in
                let snapshotKey = paneID.lowercased()
                let recordURL = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
                let privateIndexURL = repo.url.appendingPathComponent(".git/limpid/turn-\(snapshotKey).index")
                let readIndexURL = repo.url.appendingPathComponent(".git/limpid/turn-\(snapshotKey).read.index")
                let paneRef = "refs/limpid/turn/\(snapshotKey)"
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
                if eventIndex == 0 {
                    baseTree = try #require(record?["turnBaseTree"] as? String)
                    #expect(baseTree == expectedTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                    // The record holds the tree; the pane has no ref of its own.
                    #expect(try gitExitStatus(["show-ref", "--verify", "--quiet", paneRef], in: repo.url) == 1)
                    // A pane ref and a read index left in the repository,
                    // which SessionEnd removes along with the private index.
                    #expect(try gitExitStatus(["update-ref", paneRef, baseTree], in: repo.url) == 0)
                    #expect(FileManager.default.fileExists(atPath: privateIndexURL.path))
                    try Data().write(to: readIndexURL)
                } else if eventIndex == 1 {
                    #expect(record?["turnBaseTree"] as? String == baseTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                } else {
                    #expect(record?["turnBaseTree"] == nil)
                    #expect(try gitExitStatus(["show-ref", "--verify", "--quiet", paneRef], in: repo.url) == 1)
                    #expect(!FileManager.default.fileExists(atPath: privateIndexURL.path))
                    #expect(!FileManager.default.fileExists(atPath: readIndexURL.path))
                }
            }
        )
        #expect(!baseTree.isEmpty)
        #expect(try await repo.git(["status", "--porcelain"]) == status)
        #expect(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date == indexMTime
        )
    }

    @Test("skips disabled, non-repository, and missing-Git snapshots", arguments: HookAgent.allCases)
    func promptSnapshot_skipConditionsOmitFields(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let prompt = agent.payload("UserPromptSubmit", extra: ["cwd": repo.url.path])
        let disabled = try runHooks(agent, [prompt], extraEnvironment: ["LIMPID_TURN_SNAPSHOT": "0"])
        let outsideRepository = try runHooks(agent, [agent.payload("UserPromptSubmit")])
        let missingGit = try withTempDir { directory in
            try runHooks(agent, [prompt], extraEnvironment: ["PATH": pathWithoutGit(in: directory)])
        }
        for optionalRecord in [disabled, outsideRepository, missingGit] {
            let record = try #require(optionalRecord)
            #expect(record["turnBaseTree"] == nil)
            #expect(record["turnRoot"] == nil)
        }
    }

    /// A turn's scratch files go in the git directory git names as an
    /// absolute path, from the top of the worktree and from a folder inside
    /// it. `git rev-parse --git-dir` prints `.git` at the top, and `.git`
    /// resolved against a root URL with no trailing slash lands in the root's
    /// parent: a temporary repository's snapshot would go to
    /// `$TMPDIR/.git/limpid`, shared by every later run.
    @Test("writes a turn's scratch files only inside the repository's git directory", arguments: HookAgent.allCases)
    func promptSnapshot_staysInsideTheRepositoryGitDirectory(agent: HookAgent) async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let nested = repo.url.appendingPathComponent("src/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for cwd in [repo.url, nested] {
            let record = try #require(try runHooks(agent, [
                agent.payload("UserPromptSubmit", extra: ["cwd": cwd.path]),
                agent.payload("Stop", extra: ["cwd": cwd.path])
            ]))
            #expect(record["turnRoot"] != nil)
        }
        let limpid = repo.url.appendingPathComponent(".git/limpid")
        #expect(FileManager.default.fileExists(atPath: limpid.path))
        let beside = try FileManager.default.contentsOfDirectory(atPath: repo.scratch.path)
        #expect(beside == [repo.url.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: nested.appendingPathComponent(".git").path))
    }

    // MARK: - Pid

    /// The shim exports its own pid and then `exec`s the agent, so outside
    /// tmux the value already is the process the Swift-side liveness sweep
    /// watches. Guessing by process name cannot tell two agents in one tree
    /// apart; the exported value can.
    @Test("prefers the pid the shim exported", arguments: HookAgent.allCases)
    func exportedPid_isRecorded(agent: HookAgent) throws {
        let record = try runHooks(agent, agent.midTurn(), extraEnvironment: [agent.pidVariable: "424242"])
        #expect(record?["pid"] as? String == "424242")
    }

    /// The value reaches the record's JSON verbatim, and an inherited
    /// variable is not numeric by construction the way a value read out of
    /// `ps` is. A malformed record is dropped whole by the projection's record
    /// scan, taking the pane's badge with it.
    @Test("refuses an exported pid that is not a number", arguments: HookAgent.allCases)
    func nonNumericExportedPid_isRefused(agent: HookAgent) throws {
        let record = try runHooks(agent, agent.midTurn(), extraEnvironment: [agent.pidVariable: "\" ,\"x\":1"])
        #expect(record?["pid"] == nil)
    }

    /// Inside tmux the shim publishes its own pid and then `exec`s tmux, so
    /// the value names the client rather than the agent, and the client is
    /// gone on the first detach. The walk is the only source that finds the
    /// agent wherever tmux placed it, so the inherited value is dropped.
    @Test("ignores the exported pid inside tmux, where it names the client", arguments: HookAgent.allCases)
    func exportedPid_isIgnoredInsideTmux(agent: HookAgent) throws {
        let record = try runHooks(
            agent,
            agent.midTurn(),
            extraEnvironment: [agent.pidVariable: "424242", "TMUX": "/tmp/tmux-501/default,4242,0"]
        )
        #expect(record?["pid"] == nil)
    }

    @Test("records no pid when the shim exported none", arguments: HookAgent.allCases)
    func noExportedPid_leavesThePidFieldOff(agent: HookAgent) throws {
        let record = try runHooks(agent, agent.midTurn(), extraEnvironment: [agent.pidVariable: ""])
        #expect(record?["pid"] == nil)
    }

    /// The pid tests above are also satisfied by a walk that never matches
    /// anything, because nothing in the test host's ancestry carries the
    /// agent's name. Inside tmux the walk is the only source of the pid, so
    /// one test proves it finds something.
    @Test("walks up to an ancestor named after the agent when no pid was exported", arguments: HookAgent.allCases)
    func walk_findsTheAncestorNamedAfterTheAgent(agent: HookAgent) throws {
        try withTempDir { dir in
            let paneID = UUID().uuidString
            // `ps` reports the path a process was exec'd as rather than the
            // resolved one, so a symlink hands the walk an ancestor with the
            // name it looks for, and exercises the basename stripping at the
            // same time. A copy of `sh` would not work: macOS kills a
            // relocated system binary on launch (exit 137).
            let fakeAgent = dir.appendingPathComponent(agent.rawValue)
            try FileManager.default.createSymbolicLink(at: fakeAgent, withDestinationURL: URL(fileURLWithPath: "/bin/sh"))
            let process = Process()
            process.executableURL = fakeAgent
            // The trailing `true` keeps the shell from exec'ing the hook in
            // place, which would drop the agent-named process out of the very
            // chain the walk has to climb.
            process.arguments = try ["-c", "/bin/sh '\(agent.wrapper().path)'; true"]
            var environment = agent.environment(in: dir, paneID: paneID)
            environment["LIMPID_HOOK_HELPER"] = try #require(HookHelperFixture.helperURL).path
            process.environment = IsolatedProcessEnvironment.make(environment)
            try HookScriptHarness.feed(agent.payload("SessionStart"), to: process)

            let url = try dir.appendingPathComponent("states/" + AgentRecordFixtures.recordFileName(paneID))
            let record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(record?["pid"] as? String == String(process.processIdentifier))
        }
    }

    // MARK: - Tmux

    /// The pane strip's tab marks a hosted pane from this flag, and the
    /// record is what clears it: `SessionEnd` and the pid sweep drop the
    /// whole record, so nothing has to notice the tmux session went away.
    @Test("records that the agent is hosted in tmux", arguments: HookAgent.allCases)
    func insideTmux_recordsTheHostedFlag(agent: HookAgent) throws {
        let record = try runHooks(agent, agent.midTurn(), extraEnvironment: ["TMUX": "/tmp/tmux-501/limpid,4242,0"])
        #expect(record?["isTmuxHosted"] as? Bool == true)
    }

    @Test("leaves the hosted flag off outside tmux", arguments: HookAgent.allCases)
    func outsideTmux_omitsTheHostedFlag(agent: HookAgent) throws {
        #expect(try runHooks(agent, agent.midTurn())?["isTmuxHosted"] == nil)
    }

    // MARK: - Fixture recording

    /// Fixture recording has to keep the bytes the agent sent, not the
    /// helper's reading of them, so this compares the file against the stdin
    /// bytes rather than against the parsed record. The transcript copy is
    /// what the title rules are later replayed from.
    @Test("records raw payloads and the transcript when LIMPID_HOOK_RECORD_DIR is set", arguments: HookAgent.allCases)
    func recordDirectory_keepsRawPayloadsInOrder(agent: HookAgent) throws {
        try withTempDir { recordRoot in
            let recordDir = recordRoot.appendingPathComponent("record")
            try FileManager.default.createDirectory(at: recordDir, withIntermediateDirectories: true)
            let transcript = recordRoot.appendingPathComponent("transcript.jsonl")
            let transcriptBytes = Data("{\"type\":\"ai-title\",\"aiTitle\":\"Fixture\"}\n".utf8)
            try transcriptBytes.write(to: transcript)
            let payloads = [
                agent.payload("SessionStart", extra: ["transcript_path": transcript.path]),
                agent.payload("UserPromptSubmit", extra: ["prompt": "count \"quoted\" \\ things"])
            ]

            _ = try runHooks(agent, payloads, extraEnvironment: ["LIMPID_HOOK_RECORD_DIR": recordDir.path])

            let recorded = try FileManager.default.contentsOfDirectory(atPath: recordDir.path).sorted()
            #expect(recorded == [
                "0000-SessionStart.json",
                "0000-SessionStart.transcript.jsonl",
                "0001-UserPromptSubmit.json"
            ])
            for (index, name) in ["0000-SessionStart.json", "0001-UserPromptSubmit.json"].enumerated() {
                let bytes = try Data(contentsOf: recordDir.appendingPathComponent(name))
                let sent = try JSONSerialization.data(withJSONObject: payloads[index])
                #expect(bytes.count == sent.count, "\(name) was rewritten rather than copied")
                let parsed = try JSONSerialization.jsonObject(with: bytes) as? NSDictionary
                #expect(parsed == payloads[index] as NSDictionary)
            }
            let copiedTranscript = try Data(contentsOf: recordDir.appendingPathComponent("0000-SessionStart.transcript.jsonl"))
            #expect(copiedTranscript == transcriptBytes)
        }
    }

    @Test("leaves no recording behind when the directory does not exist", arguments: HookAgent.allCases)
    func recordDirectory_missing_isIgnored(agent: HookAgent) throws {
        try withTempDir { recordRoot in
            let missing = recordRoot.appendingPathComponent("absent")
            let record = try runHooks(agent, agent.midTurn(), extraEnvironment: ["LIMPID_HOOK_RECORD_DIR": missing.path])
            #expect(record?["state"] as? String == "running")
            #expect(!FileManager.default.fileExists(atPath: missing.path))
        }
    }

    // MARK: - Wrapper

    /// The helper is the only receiver, so a bundle without it records
    /// nothing: the wrapper says so on stderr, which the agent shows, and
    /// fails the call rather than exit 0 as if it had been recorded.
    @Test("fails loudly when the helper is missing", arguments: HookAgent.allCases)
    func wrapper_withoutHelper_failsLoudly(agent: HookAgent) throws {
        try withTempDir { dir in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = try [agent.wrapper().path]
            process.environment = IsolatedProcessEnvironment.make([
                "PATH": ShimHarness.systemPath,
                "HOME": dir.path,
                "LIMPID_HOOK_HELPER": dir.appendingPathComponent("AgentIntegrationHookHelper").path,
                "LIMPID_PANE_ID": UUID().uuidString
            ])
            // A file rather than a pipe, so the wrapper never blocks on a
            // full pipe while we wait for it to exit.
            let stderrURL = dir.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            process.standardError = try FileHandle(forWritingTo: stderrURL)
            try HookScriptHarness.feed(agent.payload("SessionStart"), to: process)
            #expect(process.terminationStatus == 1)
            #expect(try String(contentsOf: stderrURL, encoding: .utf8).contains("Hook Helper is missing"))
        }
    }

    /// An agent's settings may name the wrapper through a link, and the
    /// wrapper finds the helper and keeps the run's identity either way.
    @Test("runs the same through a link to the wrapper", arguments: HookAgent.allCases)
    func linkedWrapper_keepsTheRunIdentityAndRevision(agent: HookAgent) throws {
        try withTempDir { linkDir in
            let link = linkDir.appendingPathComponent("limpid-hook")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: agent.wrapper())
            let runID = UUID().uuidString
            let record = try runHooks(agent, agent.midTurn(), extraEnvironment: ["LIMPID_AGENT_RUN_ID": runID], wrapper: link)
            #expect(record?["runId"] as? String == runID)
            #expect(record?["revision"] as? Int == 2)
        }
    }

    /// A record named by the pane id is what an older writer leaves, and it
    /// may still be running beside the new one; a run keyed by its run id
    /// writes its own file and leaves that one alone.
    @Test("leaves a record named by the pane id alone", arguments: HookAgent.allCases)
    func runRecord_leavesAPaneNamedRecordAlone(agent: HookAgent) throws {
        let runID = UUID().uuidString
        let sentinel = Data("another writer owns this file".utf8)
        var paneNamed: URL?
        let record = try runHooks(
            agent,
            [agent.payload("SessionStart")],
            extraEnvironment: ["LIMPID_AGENT_RUN_ID": runID],
            afterEach: { _, _, _, _ in
                let contents = try paneNamed.map { try Data(contentsOf: $0) }
                #expect(contents == sentinel)
            },
            prepare: { _, states, paneID in
                try FileManager.default.createDirectory(at: states, withIntermediateDirectories: true)
                let url = try states.appendingPathComponent(AgentRecordFixtures.recordFileName(paneID))
                try sentinel.write(to: url)
                paneNamed = url
            }
        )
        #expect(record?["runId"] as? String == runID)
    }

    // MARK: - Lifecycle

    @Test("replays a run's lifecycle transitions event by event", arguments: HookAgent.allCases)
    func lifecycle_replaysEachTransition(agent: HookAgent) throws {
        let steps = agent.lifecycle
        let records = try HookScriptHarness.replayRecords(agent, steps.map(\.payload))

        try #require(records.count == steps.count)
        for (index, step) in steps.enumerated() {
            let record = records[index]
            let event = step.payload["hook_event_name"] as? String ?? ""
            #expect(record["schemaVersion"] as? Int == 3, "step \(index) \(event)")
            #expect(record["state"] as? String == step.state, "step \(index) \(event)")
            #expect(record["revision"] as? Int == index + 1, "step \(index) \(event)")
            #expect(record["stateEpisodeToken"] as? String == String(step.episodeToken), "step \(index) \(event)")
            #expect(record["lastHookEvent"] as? String == step.lastHookEvent, "step \(index) \(event)")
            for (key, expected) in step.texts {
                #expect(optionalText(record, key) == expected, "step \(index) \(event): \(key)")
            }
            if let contextTokens = step.contextTokens {
                #expect(record["contextTokens"] as? Int == contextTokens, "step \(index) \(event)")
            }
        }
        // Every start refreshes `sessionStartedAt`, so across the final
        // SessionStart the value can only move forward; equality would hold
        // only while both events landed in the same second.
        let restartedAt = try #require(optionalText(records[records.count - 1], "sessionStartedAt"))
        let previousAt = try #require(optionalText(records[records.count - 2], "sessionStartedAt"))
        #expect(restartedAt >= previousAt)
    }

    /// The events the agent is told to call us on are the list the helper
    /// has to keep up with. An event subscribed but never mapped leaves the
    /// pane frozen on its last state, and nothing else notices.
    @Test("every subscribed event maps to a lifecycle state", arguments: HookAgent.allCases)
    func subscribedEvents_allReachABranch(agent: HookAgent) throws {
        let events = try agent.lifecycleSubscriptions()
        #expect(!events.isEmpty)
        for event in events {
            let record = try runHooks(agent, agent.midTurn() + [agent.payload(event, extra: agent.extras(for: event))])
            let mapped = try #require(agent.neutralEvents[event], "no neutral event named for \(event)")
            #expect(record?["lastHookEvent"] as? String == mapped, "the hook runtime has no branch for \(event)")
        }
    }

    @Test("keeps one episode token across repeated waiting writes", arguments: HookAgent.allCases)
    func waitingEpisode_repeatedState_keepsToken(agent: HookAgent) throws {
        let record = try runHooks(agent, [agent.payload("UserPromptSubmit"), agent.waitingPayload, agent.waitingPayload])
        #expect(record?["state"] as? String == "needsInput")
        #expect(record?["revision"] as? Int == 3)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    @Test("keys one invocation by run id and increments its revision", arguments: HookAgent.allCases)
    func runIdentity_multipleEvents_shareOneOrderedRecord(agent: HookAgent) throws {
        let runID = UUID().uuidString
        let record = try runHooks(agent, agent.midTurn(), extraEnvironment: ["LIMPID_AGENT_RUN_ID": runID])
        #expect(record?["runId"] as? String == runID)
        #expect(record?["revision"] as? Int == 2)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    // MARK: - Files the app reads by name

    /// The app finds a pane's resume hint by the name the Rust writer
    /// reports. The helper spells it itself, so reading the hint back by the
    /// reported name is what catches a writer that drifts.
    @Test("writes the resume hint under the name the app reads", arguments: HookAgent.allCases)
    func resumeHint_usesTheReportedName(agent: HookAgent) throws {
        var wasRead = false
        _ = try runHooks(agent, [agent.payload("SessionStart")]) { dir, _, paneID, _ in
            let url = try dir.appendingPathComponent("sessions/" + AgentRecordFixtures.hintFileName(paneID))
            let hint = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(hint?["paneId"] as? String == paneID)
            wasRead = true
        }
        #expect(wasRead)
    }

    // MARK: - Helpers

    private func gitExitStatus(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        #expect(process.waitUntilExit(within: 10))
        return process.terminationStatus
    }

    /// The tree `git add -A` would write for `repository`, built on a copy of
    /// its index so the real one is left untouched.
    private func scratchTree(in repository: URL) throws -> String {
        try withTempDir { directory in
            let index = directory.appendingPathComponent("index")
            try FileManager.default.copyItem(at: repository.appendingPathComponent(".git/index"), to: index)
            let environment = ProcessInfo.processInfo.environment.merging(
                ["GIT_INDEX_FILE": index.path, "GIT_OPTIONAL_LOCKS": "0"]
            ) { _, new in new }
            var tree = ""
            for arguments in [["add", "-A"], ["write-tree"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", repository.path] + arguments
                process.environment = environment
                let output = directory.appendingPathComponent("out")
                FileManager.default.createFile(atPath: output.path, contents: nil)
                process.standardOutput = try FileHandle(forWritingTo: output)
                try process.run()
                #expect(process.waitUntilExit(within: 10))
                #expect(process.terminationStatus == 0)
                tree = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return tree
        }
    }

    /// A PATH holding the tools the wrapper and helper use, without git.
    private func pathWithoutGit(in directory: URL) throws -> String {
        let bin = directory.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for command in [
            "awk", "cat", "cp", "dirname", "grep", "head", "mkdir", "mv",
            "plutil", "ps", "readlink", "rm", "sed", "sleep", "tail", "tr"
        ] {
            let candidates = ["/usr/bin/\(command)", "/bin/\(command)", "/usr/sbin/\(command)"]
            guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else { continue }
            try FileManager.default.createSymbolicLink(
                at: bin.appendingPathComponent(command),
                withDestinationURL: URL(fileURLWithPath: source)
            )
        }
        return bin.path
    }
}

/// One event of a replayed run and the record it should leave.
private struct LifecycleStep {
    let payload: [String: Any]
    let state: String
    let lastHookEvent: String
    let episodeToken: Int
    /// Text fields the record should hold after this event; a nil value
    /// means the field is absent.
    var texts: [String: String?] = [:]
    var contextTokens: Int?
}

private extension HookAgent {
    /// A run that visits every state the agent's events lead to, ending in a
    /// SessionStart: a compaction mid-turn for Claude, a restart for Codex.
    var lifecycle: [LifecycleStep] {
        switch self {
        case .claude:
            [
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "startup", "session_title": "Opening title"]),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 1,
                    texts: ["providerSessionTitle": "Opening title"]
                ),
                // A later hook omits the SessionStart fields, and the title
                // carries over.
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 2,
                    texts: [
                        "firstPrompt": "Opening prompt", "lastPrompt": "Opening prompt",
                        "providerSessionTitle": "Opening title"
                    ]
                ),
                LifecycleStep(
                    payload: payload("PreToolUse", extra: [
                        "tool_name": "AskUserQuestion",
                        "tool_input": ["questions": [["question": "Choose a branch"]]]
                    ]),
                    state: "needsInput", lastHookEvent: "waiting_for_input", episodeToken: 3
                ),
                LifecycleStep(
                    payload: payload("PreCompact", extra: ["current_token_count": 42]),
                    state: "compacting", lastHookEvent: "compacting", episodeToken: 4, contextTokens: 42
                ),
                LifecycleStep(
                    payload: payload("Stop"),
                    state: "finished", lastHookEvent: "turn_finished", episodeToken: 5,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("StopFailure", extra: ["error": "overloaded"]),
                    state: "error", lastHookEvent: "failed", episodeToken: 6,
                    texts: ["runStartedAt": nil, "detail": "overloaded"]
                ),
                LifecycleStep(
                    payload: payload("SessionEnd", extra: ["reason": "other"]),
                    state: "unknown", lastHookEvent: "session_ended", episodeToken: 7,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "startup", "session_title": "Replacement title"]),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 8,
                    texts: [
                        "firstPrompt": nil, "providerGeneratedTitle": nil,
                        "providerSessionTitle": "Replacement title"
                    ]
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Second prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 9
                ),
                // A compaction mid-turn keeps the turn open (`lifecycle.rs`):
                // the state stays running, so the episode goes on with it, and
                // the title and the opening prompt carry across.
                LifecycleStep(
                    payload: payload("SessionStart", extra: ["source": "compact"]),
                    state: "running", lastHookEvent: "session_started", episodeToken: 9,
                    texts: ["firstPrompt": "Second prompt", "providerSessionTitle": "Replacement title"]
                )
            ]
        case .codex:
            [
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 1
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 2,
                    texts: ["firstPrompt": "Opening prompt", "lastPrompt": "Opening prompt"]
                ),
                LifecycleStep(
                    payload: payload("PermissionRequest", extra: ["message": "Approval required"]),
                    state: "needsInput", lastHookEvent: "approval_requested", episodeToken: 3,
                    texts: ["detail": "Approval required"]
                ),
                LifecycleStep(
                    payload: payload("PreCompact", extra: ["current_token_count": 42]),
                    state: "compacting", lastHookEvent: "compacting", episodeToken: 4, contextTokens: 42
                ),
                LifecycleStep(
                    payload: payload("Stop"),
                    state: "finished", lastHookEvent: "turn_finished", episodeToken: 5,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionEnd", extra: ["reason": "other"]),
                    state: "unknown", lastHookEvent: "session_ended", episodeToken: 6,
                    texts: ["runStartedAt": nil]
                ),
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 7,
                    texts: ["firstPrompt": nil]
                ),
                LifecycleStep(
                    payload: payload("UserPromptSubmit", extra: ["prompt": "Second prompt"]),
                    state: "running", lastHookEvent: "prompt_submitted", episodeToken: 8
                ),
                // Codex sends no Stop for an interrupted turn, so Interrupt
                // ends it: the turn ended, only early.
                LifecycleStep(
                    payload: payload("Interrupt", extra: ["turn_id": "01a072a0-4bb0-7020-959e-40c97c391d17"]),
                    state: "finished", lastHookEvent: "interrupted", episodeToken: 9,
                    texts: ["runStartedAt": nil]
                ),
                // Codex does not mark SessionStart as compact; its compaction
                // boundary is the separate PreCompact/PostCompact pair.
                LifecycleStep(
                    payload: payload("SessionStart"),
                    state: "idle", lastHookEvent: "session_started", episodeToken: 10,
                    texts: ["firstPrompt": nil]
                )
            ]
        }
    }

    /// The events the agent is told to call the hook on that end in a
    /// lifecycle state. Claude's come from `settings.template.json`, which the
    /// shim hands to `claude --settings`; `CwdChanged` writes a cwd event
    /// instead, and the approval and subagent hooks go elsewhere.
    func lifecycleSubscriptions() throws -> [String] {
        switch self {
        case .claude:
            let root = try #require(RepoFixture.limpidRoot)
            let template = root.appendingPathComponent("rust/limpid-provider-claude/resources/settings.template.json")
            let filled = try String(contentsOf: template, encoding: .utf8)
                .replacingOccurrences(of: "@@HOOK@@", with: "/hook")
                .replacingOccurrences(of: "@@WORKTREE_PRETOOL_HOOK@@", with: "/pretool")
                .replacingOccurrences(of: "@@APPROVAL_HELPER@@", with: "/approval-helper")
            let json = try JSONSerialization.jsonObject(with: Data(filled.utf8))
            let hooks = try #require((json as? [String: Any])?["hooks"] as? [String: Any])
            return hooks.keys.sorted().filter { !["CwdChanged", "PermissionRequest", "SubagentStop"].contains($0) }
        case .codex:
            return CodexHookInstaller.subscribedEvents.map(\.jsonKey)
        }
    }

    /// The provider-neutral event each subscribed hook records as
    /// `lastHookEvent` (each provider crate's normalization).
    var neutralEvents: [String: String] {
        switch self {
        case .claude:
            [
                "Notification": "approval_requested",
                "PostToolUse": "tool_finished",
                "PostToolUseFailure": "tool_finished",
                "PreCompact": "compacting",
                "PreToolUse": "tool_started",
                "SessionEnd": "session_ended",
                "SessionStart": "session_started",
                "Stop": "turn_finished",
                "StopFailure": "failed",
                "UserPromptSubmit": "prompt_submitted"
            ]
        case .codex:
            [
                "SessionStart": "session_started",
                "SessionEnd": "session_ended",
                "UserPromptSubmit": "prompt_submitted",
                "PreToolUse": "tool_started",
                "PostToolUse": "tool_finished",
                "PreCompact": "compacting",
                "PostCompact": "compaction_finished",
                "PermissionRequest": "approval_requested",
                "Interrupt": "interrupted",
                "Stop": "turn_finished"
            ]
        }
    }

    /// The fields an event needs before it reaches a state at all. A Claude
    /// `Notification` that is not a permission prompt is deliberately
    /// ignored, and its tool events key off the tool name.
    func extras(for event: String) -> [String: Any] {
        guard self == .claude else { return [:] }
        return switch event {
        case "Notification": ["notification_type": "permission_prompt", "message": "needs permission"]
        case "PreToolUse": ["tool_name": "Bash"]
        case "PostToolUse", "PostToolUseFailure": ["tool_name": "AskUserQuestion"]
        case "StopFailure": ["error_type": "overloaded"]
        case "SessionEnd": ["reason": "other"]
        default: [:]
        }
    }

    /// The event the agent sends while it waits for the person's permission.
    var waitingPayload: [String: Any] {
        switch self {
        case .claude: payload("Notification", extra: ["notification_type": "permission_prompt"])
        case .codex: payload("PermissionRequest")
        }
    }
}
