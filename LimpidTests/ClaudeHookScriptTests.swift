// ClaudeHookScriptTests.swift
// Limpid — what only Claude's hook calls carry, run through
// `claude-shim/limpid-hook` and the Hook Helper: the conversation's titles,
// a question's answer, the working-directory event, and a quit.

import Foundation
import Testing
@testable import Limpid

@Suite(
    "Claude hook receiver",
    .tags(.smoke),
    .disabled(if: !RepoFixture.hasLocalRepo, "no local git"),
    // Running the test bundle without its app host leaves no helper to
    // exec, which is a missing precondition rather than a failure.
    .disabled(if: HookHelperFixture.helperURL == nil, "no hook helper beside the test host"),
    .timeLimit(.minutes(1))
)
struct ClaudeHookScriptTests {
    private let agent = HookAgent.claude

    private func runHooks(
        _ payloads: [[String: Any]],
        afterEach: ((URL, URL, String, Int) throws -> Void)? = nil,
        prepare: ((URL, URL, String) throws -> Void)? = nil
    ) throws -> [String: Any]? {
        try HookScriptHarness.runHooks(agent, payloads, afterEach: afterEach, prepare: prepare)
    }

    @Test("records Claude's documented SessionStart title and conversation identity")
    func sessionStart_formalTitle_isRecorded() throws {
        let record = try runHooks([
            agent.payload("SessionStart", extra: ["source": "startup", "session_title": "Formal \"session\" title"])
        ])
        #expect(record?["sessionId"] as? String == agent.sessionID)
        #expect(record?["providerSessionTitle"] as? String == "Formal \"session\" title")
        #expect(record?["providerGeneratedTitle"] == nil)
    }

    @Test("uses transcript titles as compatibility observations")
    func transcriptTitle_laterTurn_updatesCandidates() throws {
        try withTempDir { dir in
            let transcript = dir.appendingPathComponent("transcript.jsonl")
            try """
            {"type": "ai-title", "aiTitle": "Generated title", "customTitle": "Renamed title"}
            """.write(to: transcript, atomically: true, encoding: .utf8)

            let record = try runHooks([
                agent.payload("SessionStart", extra: ["source": "startup"]),
                agent.payload("UserPromptSubmit", extra: ["prompt": "Opening prompt", "transcript_path": transcript.path])
            ])

            #expect(record?["providerSessionTitle"] as? String == "Renamed title")
            #expect(record?["providerGeneratedTitle"] as? String == "Generated title")
        }
    }

    @Test(arguments: ["PostToolUse", "PostToolUseFailure"])
    func completedQuestion_resumesWithoutClearingAnUnrelatedTool(_ event: String) throws {
        let waiting = [
            agent.payload("UserPromptSubmit"),
            agent.payload("PreToolUse", extra: [
                "tool_name": "AskUserQuestion",
                "tool_input": ["questions": [["question": "Which color?"]]]
            ])
        ]
        let unrelated = try runHooks(waiting + [agent.payload(event, extra: ["tool_name": "Bash"])])
        #expect(unrelated?["state"] as? String == "needsInput")
        let answered = try runHooks(waiting + [agent.payload(event, extra: ["tool_name": "AskUserQuestion"])])
        #expect(answered?["state"] as? String == "running")
    }

    /// The app finds a pane's cwd event by the name the Rust writer reports.
    /// The helper spells it itself, so reading the event back by the
    /// reported name is what catches a writer that drifts.
    @Test("writes the cwd event under the name the app reads")
    func cwdEvent_usesTheReportedName() throws {
        var wasRead = false
        _ = try runHooks([
            agent.payload("SessionStart"),
            agent.payload("CwdChanged", extra: ["old_cwd": "/tmp", "new_cwd": "/private/tmp"])
        ]) { dir, _, paneID, eventIndex in
            guard eventIndex == 1 else { return }
            let url = try dir.appendingPathComponent("cwd/" + AgentRecordFixtures.cwdEventFileName(paneID))
            let event = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            #expect(event?["paneId"] as? String == paneID)
            #expect(event?["newCwd"] as? String == "/private/tmp")
            wasRead = true
        }
        #expect(wasRead)
    }

    /// Quitting Claude ends the conversation, so its resume hint goes; a
    /// hint the pane holds for another conversation is not this quit's to
    /// remove.
    @Test("a quit removes only the resume hint of its own conversation", arguments: [true, false])
    func quit_removesOnlyItsOwnConversationsHint(isOwnConversation: Bool) throws {
        let hintSession = isOwnConversation ? agent.sessionID : UUID().uuidString.lowercased()
        var hint: URL?
        var isHintLeft: Bool?
        _ = try runHooks(
            [agent.payload("SessionEnd", extra: ["reason": "quit"])],
            afterEach: { _, _, _, _ in
                isHintLeft = hint.map { FileManager.default.fileExists(atPath: $0.path) }
            },
            prepare: { dir, _, paneID in
                let sessions = dir.appendingPathComponent("sessions")
                try AgentRecordFixtures.write(
                    AgentSessionHintFixture(
                        paneId: paneID, sessionId: hintSession, cwd: dir.path, updatedAt: "2026-09-09T00:00:00Z"
                    ),
                    to: sessions
                )
                hint = try sessions.appendingPathComponent(AgentRecordFixtures.hintFileName(paneID))
            }
        )
        #expect(isHintLeft == !isOwnConversation)
    }
}
