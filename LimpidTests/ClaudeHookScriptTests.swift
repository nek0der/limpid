// ClaudeHookScriptTests.swift
// Limpid — runs `claude-shim/limpid-hook` against captured Claude Code
// payloads. It is the larger of the two receivers and had no coverage of
// its own until layer 2 forced the pid handling open; this suite starts
// from the harness `CodexHookScriptTests` uses and covers the pid
// resolution plus the event mapping. The rest of the receiver — prompt
// carry-over and cwd events — is only partially covered.

import Foundation
import Testing
@testable import Limpid

@Suite("Claude hook receiver", .tags(.smoke), .disabled(if: !RepoFixture.hasLocalRepo, "no local git"))
struct ClaudeHookScriptTests {
    /// Replay `payloads` through the receiver against one pane, in order,
    /// and return the lifecycle record left behind — or `nil` when the
    /// receiver declined to write one. Runs against a temp state dir so
    /// the developer's real records are never touched.
    private func runHooks(
        _ payloads: [[String: Any]],
        extraEnvironment: [String: String] = [:],
        afterEach: ((URL, URL, String, Int) throws -> Void)? = nil
    ) throws -> [String: Any]? {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let script = root.appendingPathComponent(
                "Limpid/Resources/claude-shim/limpid-hook"
            )
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString

            for (eventIndex, payload) in payloads.enumerated() {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = [script.path]
                // `HOME` is redirected too: the receiver falls back to
                // `$HOME/Library/...` when the state dir is unset, and a typo
                // in the env below must not send writes at the real one.
                process.environment = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": dir.path,
                    "LIMPID_PANE_ID": paneID,
                    "LIMPID_AGENT_STATES_DIR": states.path,
                    "LIMPID_SESSIONS_DIR": dir.appendingPathComponent("sessions").path,
                    "LIMPID_CWD_EVENTS_DIR": dir.appendingPathComponent("cwd").path
                ]
                process.environment?.merge(extraEnvironment) { _, new in new }
                let stdin = Pipe()
                process.standardInput = stdin
                try process.run()
                try stdin.fileHandleForWriting.write(
                    contentsOf: JSONSerialization.data(withJSONObject: payload)
                )
                try stdin.fileHandleForWriting.close()
                process.waitUntilExit()
                // The receiver's stated failure policy is to exit 0 no matter
                // what, so that a broken hook never blocks Claude from running.
                #expect(process.terminationStatus == 0)
                try afterEach?(dir, states, paneID, eventIndex)
            }

            let recordID = extraEnvironment["LIMPID_AGENT_RUN_ID"] ?? paneID
            let record = states.appendingPathComponent("\(recordID).state.json")
            guard let data = try? Data(contentsOf: record) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func gitOutput(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private func gitExitStatus(_ arguments: [String], in directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func scratchTree(in repository: URL) throws -> String {
        try withTempDir { directory in
            let index = directory.appendingPathComponent("index")
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent(".git/index"),
                to: index
            )
            let environment = ProcessInfo.processInfo.environment.merging(
                ["GIT_INDEX_FILE": index.path, "GIT_OPTIONAL_LOCKS": "0"]
            ) { _, new in new }
            for arguments in [["add", "-A"], ["write-tree"]] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = ["-C", repository.path] + arguments
                process.environment = environment
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                process.waitUntilExit()
                #expect(process.terminationStatus == 0)
                if arguments == ["write-tree"] {
                    return String(
                        data: output.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
            }
            return ""
        }
    }

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

    /// A turn in flight: the receiver has stamped `runStartedAt` and is
    /// waiting for whatever ends the turn.
    private func midTurn() -> [[String: Any]] {
        [
            payload("SessionStart"),
            payload("UserPromptSubmit", extra: ["prompt": "count to 200"])
        ]
    }

    /// Shape mirrors what Claude Code sends on the wire; `extra` carries
    /// the per-event fields.
    private func payload(_ event: String, extra: [String: Any] = [:]) -> [String: Any] {
        var base: [String: Any] = [
            "session_id": "6f1d6a1e-0e34-4a1a-9a8e-2f2b6c1d7f10",
            "cwd": "/tmp",
            "hook_event_name": event
        ]
        base.merge(extra) { _, new in new }
        return base
    }

    @Test("captures an exact private prompt snapshot without changing the real index")
    func promptSnapshot_isPrivateAndSessionEndCleansIt() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let file = repo.url.appendingPathComponent("pending.txt")
        try Data("before prompt\n".utf8).write(to: file)
        let status = try gitOutput(["status", "--porcelain"], in: repo.url)
        let expectedRoot = try gitOutput(["rev-parse", "--show-toplevel"], in: repo.url)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expectedTree = try scratchTree(in: repo.url)
        let indexURL = repo.url.appendingPathComponent(".git/index")
        let indexMTime = try #require(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date
        )
        var baseTree = ""
        _ = try runHooks(
            [
                payload("UserPromptSubmit", extra: ["cwd": repo.url.path]),
                payload("Stop", extra: ["cwd": repo.url.path]),
                payload("SessionEnd", extra: ["cwd": repo.url.path, "reason": "other"])
            ],
            afterEach: { _, states, paneID, eventIndex in
                let snapshotKey = paneID.lowercased()
                let recordURL = states.appendingPathComponent("\(paneID).state.json")
                let privateIndexURL = repo.url.appendingPathComponent(".git/limpid/turn-\(snapshotKey).index")
                let readIndexURL = repo.url.appendingPathComponent(".git/limpid/turn-\(snapshotKey).read.index")
                let record = try JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any]
                if eventIndex == 0 {
                    baseTree = try #require(record?["turnBaseTree"] as? String)
                    #expect(baseTree == expectedTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                    #expect(try gitOutput(["rev-parse", "refs/limpid/turn/\(snapshotKey)"], in: repo.url)
                        .trimmingCharacters(in: .whitespacesAndNewlines) == baseTree)
                    #expect(FileManager.default.fileExists(atPath: privateIndexURL.path))
                    try Data().write(to: readIndexURL)
                } else if eventIndex == 1 {
                    #expect(record?["turnBaseTree"] as? String == baseTree)
                    #expect(record?["turnRoot"] as? String == expectedRoot)
                } else {
                    #expect(record?["turnBaseTree"] == nil)
                    #expect(try gitExitStatus(["show-ref", "--verify", "--quiet", "refs/limpid/turn/\(snapshotKey)"], in: repo.url) == 1)
                    #expect(!FileManager.default.fileExists(atPath: privateIndexURL.path))
                    #expect(!FileManager.default.fileExists(atPath: readIndexURL.path))
                }
            }
        )
        #expect(!baseTree.isEmpty)
        #expect(try gitOutput(["status", "--porcelain"], in: repo.url) == status)
        #expect(
            try (FileManager.default.attributesOfItem(atPath: indexURL.path)[.modificationDate]) as? Date == indexMTime
        )
    }

    @Test("skips disabled, non-repository, and missing-Git snapshots")
    func promptSnapshot_skipConditionsOmitFields() async throws {
        let repo = try await TempGitRepo.make()
        defer { repo.cleanup() }
        let disabled = try runHooks(
            [payload("UserPromptSubmit", extra: ["cwd": repo.url.path])],
            extraEnvironment: ["LIMPID_TURN_SNAPSHOT": "0"]
        )
        let outsideRepository = try runHooks([payload("UserPromptSubmit")])
        let missingGit = try withTempDir { directory in
            try runHooks(
                [payload("UserPromptSubmit", extra: ["cwd": repo.url.path])],
                extraEnvironment: ["PATH": pathWithoutGit(in: directory)]
            )
        }
        for optionalRecord in [disabled, outsideRepository, missingGit] {
            let record = try #require(optionalRecord)
            #expect(record["turnBaseTree"] == nil)
            #expect(record["turnRoot"] == nil)
        }
    }

    /// The shim exports its own pid and then `exec`s claude, so outside
    /// tmux the value already is the process the Swift-side liveness
    /// sweep watches.
    @Test("prefers the pid the shim exported")
    func exportedPid_isRecorded() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": "424242"])
        #expect(record?["pid"] as? String == "424242")
    }

    /// The value reaches the record's JSON verbatim, and an inherited
    /// variable is not numeric by construction the way a value read out
    /// of `ps` is. A malformed record is dropped whole by
    /// `PaneStore.allRecords`, taking the pane's badge with it — the
    /// failure #19 fixed on the Codex side and left standing here.
    @Test("refuses an exported pid that is not a number")
    func nonNumericExportedPid_isRefused() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": "\" ,\"x\":1"])
        #expect(record?["pid"] == nil)
    }

    /// Layer 2 runs the agent inside tmux, which turns the exported pid
    /// into a liability: the shim publishes its own pid and then `exec`s
    /// tmux, so the value names the client rather than the agent, and the
    /// client is gone on the first detach. Measured 2026-09-06 — a shim
    /// exporting 50626 produced an agent running as 50629. The walk is
    /// the only source that finds the agent wherever tmux placed it, so
    /// inside tmux the inherited value is dropped rather than preferred.
    @Test("ignores the exported pid inside tmux, where it names the client")
    func exportedPid_isIgnoredInsideTmux() throws {
        let record = try runHooks(
            midTurn(),
            extraEnvironment: [
                "LIMPID_CLAUDE_PID": "424242",
                "TMUX": "/tmp/tmux-501/default,4242,0"
            ]
        )
        #expect(record?["pid"] == nil)
    }

    @Test("records no pid when the shim exported none")
    func noExportedPid_leavesThePidFieldOff() throws {
        let record = try runHooks(midTurn(), extraEnvironment: ["LIMPID_CLAUDE_PID": ""])
        #expect(record?["pid"] == nil)
    }

    /// Every assertion above is also satisfied by a walk that never
    /// matches anything, because nothing in the test host's ancestry is
    /// named `claude`. Layer 2 makes the walk the only source of the pid,
    /// so it needs one test that proves it finds something.
    @Test("walks up to an ancestor named claude when no pid was exported")
    func walk_findsTheAncestorNamedClaude() throws {
        try withTempDir { dir in
            let root = try #require(RepoFixture.limpidRoot)
            let hook = root.appendingPathComponent(
                "Limpid/Resources/claude-shim/limpid-hook"
            )
            let states = dir.appendingPathComponent("states")
            let paneID = UUID().uuidString
            // `ps` reports the path a process was exec'd as rather than
            // the resolved one, so a symlink is enough to hand the walk
            // an ancestor with the name it looks for — and it exercises
            // the basename stripping at the same time. A copy of `sh`
            // would not work: macOS kills a relocated system binary on
            // launch (measured: exit 137).
            let fakeClaude = dir.appendingPathComponent("claude")
            try FileManager.default.createSymbolicLink(
                at: fakeClaude,
                withDestinationURL: URL(fileURLWithPath: "/bin/sh")
            )

            let process = Process()
            process.executableURL = fakeClaude
            // The trailing `true` keeps the shell from exec'ing the hook
            // in place, which would drop the `claude`-named process out
            // of the very chain the walk has to climb.
            process.arguments = ["-c", "/bin/sh '\(hook.path)'; true"]
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": dir.path,
                "LIMPID_PANE_ID": paneID,
                "LIMPID_AGENT_STATES_DIR": states.path,
                "LIMPID_SESSIONS_DIR": dir.appendingPathComponent("sessions").path,
                "LIMPID_CWD_EVENTS_DIR": dir.appendingPathComponent("cwd").path
            ]
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(
                contentsOf: JSONSerialization.data(withJSONObject: payload("SessionStart"))
            )
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()

            let data = try Data(
                contentsOf: states.appendingPathComponent("\(paneID).state.json")
            )
            let record = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(record?["pid"] as? String == String(process.processIdentifier))
        }
    }

    /// The tab column marks a hosted pane from this flag, and the record
    /// is what clears it: `SessionEnd` and the pid sweep drop the whole
    /// record, so nothing has to notice the tmux session went away.
    @Test("records that the agent is hosted in tmux")
    func insideTmux_recordsTheHostedFlag() throws {
        let record = try runHooks(
            midTurn(),
            extraEnvironment: ["TMUX": "/tmp/tmux-501/limpid,4242,0"]
        )
        #expect(record?["isTmuxHosted"] as? Bool == true)
    }

    @Test("leaves the hosted flag off outside tmux")
    func outsideTmux_omitsTheHostedFlag() throws {
        #expect(try runHooks(midTurn())?["isTmuxHosted"] == nil)
    }

    @Test("keys one invocation by run id and increments its revision")
    func runIdentity_multipleEvents_shareOneOrderedRecord() throws {
        let runID = UUID().uuidString
        let record = try runHooks(
            midTurn(),
            extraEnvironment: ["LIMPID_AGENT_RUN_ID": runID]
        )
        #expect(record?["runId"] as? String == runID)
        #expect(record?["revision"] as? Int == 2)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    @Test("records Claude's documented SessionStart title and conversation identity")
    func sessionStart_formalTitle_isRecorded() throws {
        let record = try runHooks([
            payload(
                "SessionStart",
                extra: [
                    "source": "startup",
                    "session_title": "Formal \"session\" title"
                ]
            )
        ])

        #expect(record?["sessionId"] as? String == "6f1d6a1e-0e34-4a1a-9a8e-2f2b6c1d7f10")
        #expect(record?["providerSessionTitle"] as? String == "Formal \"session\" title")
        #expect(record?["providerGeneratedTitle"] == nil)
    }

    @Test("preserves the formal title when later hooks omit SessionStart fields")
    func formalTitle_laterTurn_preservesObservation() throws {
        let record = try runHooks([
            payload(
                "SessionStart",
                extra: ["source": "startup", "session_title": "Formal title"]
            ),
            payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"])
        ])

        #expect(record?["providerSessionTitle"] as? String == "Formal title")
        #expect(record?["firstPrompt"] as? String == "Opening prompt")
    }

    @Test("uses transcript titles as compatibility observations")
    func transcriptTitle_laterTurn_updatesCandidates() throws {
        try withTempDir { dir in
            let transcript = dir.appendingPathComponent("transcript.jsonl")
            try """
            {"type": "ai-title", "aiTitle": "Generated title", "customTitle": "Renamed title"}
            """.write(to: transcript, atomically: true, encoding: .utf8)

            let record = try runHooks([
                payload("SessionStart", extra: ["source": "startup"]),
                payload(
                    "UserPromptSubmit",
                    extra: ["prompt": "Opening prompt", "transcript_path": transcript.path]
                )
            ])

            #expect(record?["providerSessionTitle"] as? String == "Renamed title")
            #expect(record?["providerGeneratedTitle"] as? String == "Generated title")
        }
    }

    @Test("preserves title candidates and the opening prompt across compaction")
    func compactSessionStart_preservesTitleInputs() throws {
        let record = try runHooks([
            payload(
                "SessionStart",
                extra: ["source": "startup", "session_title": "Formal title"]
            ),
            payload("UserPromptSubmit", extra: ["prompt": "Opening prompt"]),
            payload("SessionStart", extra: ["source": "compact"])
        ])

        #expect(record?["providerSessionTitle"] as? String == "Formal title")
        #expect(record?["firstPrompt"] as? String == "Opening prompt")
    }

    @Test("keeps one episode token across repeated waiting writes")
    func waitingEpisode_repeatedState_keepsToken() throws {
        let record = try runHooks([
            payload("UserPromptSubmit"),
            payload("Notification", extra: ["notification_type": "permission_prompt"]),
            payload("Notification", extra: ["notification_type": "permission_prompt"])
        ])
        #expect(record?["state"] as? String == "needsInput")
        #expect(record?["revision"] as? Int == 3)
        #expect(record?["stateEpisodeToken"] as? String == "2")
    }

    /// The template is what Claude is actually told to call us on, so it
    /// is the list the receiver has to keep up with. An event subscribed
    /// but never mapped leaves the pane frozen on its last state, and
    /// nothing else notices. `CwdChanged` is excluded because it writes a
    /// cwd event rather than a lifecycle state; it is asserted below.
    @Test("every subscribed event maps to a lifecycle state")
    func subscribedEvents_allReachABranch() throws {
        for event in try Self.subscribedEvents()
            where event != "CwdChanged" && event != "PermissionRequest"
        {
            let record = try runHooks(midTurn() + [payload(event, extra: Self.extras(for: event))])
            #expect(
                record?["lastHookEvent"] as? String == event,
                "claude-shim/limpid-hook has no branch for \(event)"
            )
        }
    }

    /// Reads the event names out of `settings.template.json`, which the
    /// shim hands to `claude --settings` after substituting hook paths.
    private static func subscribedEvents() throws -> [String] {
        let root = try #require(RepoFixture.limpidRoot)
        let template = root.appendingPathComponent(
            "Limpid/Resources/claude-shim/settings.template.json"
        )
        let filled = try String(contentsOf: template, encoding: .utf8)
            .replacingOccurrences(of: "@@HOOK@@", with: "/hook")
            .replacingOccurrences(of: "@@WORKTREE_PRETOOL_HOOK@@", with: "/pretool")
            .replacingOccurrences(of: "@@APPROVAL_HELPER@@", with: "/approval-helper")
        let json = try JSONSerialization.jsonObject(with: Data(filled.utf8))
        let hooks = try #require((json as? [String: Any])?["hooks"] as? [String: Any])
        #expect(!hooks.isEmpty)
        return hooks.keys.sorted()
    }

    /// The fields an event needs before it reaches a state at all: a
    /// `Notification` that is not a permission prompt is deliberately
    /// ignored, and `PreToolUse` keys off the tool name.
    private static func extras(for event: String) -> [String: Any] {
        switch event {
        case "Notification": ["notification_type": "permission_prompt", "message": "needs permission"]
        case "PreToolUse": ["tool_name": "Bash"]
        case "StopFailure": ["error_type": "overloaded"]
        case "SessionEnd": ["reason": "other"]
        default: [:]
        }
    }
}
