// AgentNotificationEmitterTests.swift
// Limpid — the half of a notification this process still decides.
//
// The rules choose the moment, the wording under the title, and whether it
// interrupts. What is left here is the title, the container label, and how the entry is
// filed, which is what these cases pin.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("AgentNotificationEmitter")
struct AgentNotificationEmitterTests {
    private func payload(
        kind: AgentNotificationKind,
        body: String?,
        tab: UUID,
        pane: UUID,
        presentsBanner: Bool = true
    ) throws -> AgentNotifyPayload {
        let json: [String: Any] = [
            "provider": "claude",
            "kind": kind.rawValue,
            "tab": tab.uuidString,
            "pane": pane.uuidString,
            "runtimeId": "claude:RUN",
            "body": body as Any,
            "presentsBanner": presentsBanner,
            "suppressWhenPaneFocused": true,
            "episodeToken": "4",
            "eventToken": "4",
            "state": "finished"
        ].compactMapValues { $0 is NSNull ? nil : $0 }
        return try JSONDecoder().decode(
            AgentNotifyPayload.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
    }

    private func emitter(_ history: NotificationHistoryStore) -> AgentNotificationEmitter {
        AgentNotificationEmitter(
            kind: .claude,
            notificationManager: LimpidNotificationManager(historyStore: history, appLocale: { Locale(identifier: "en") }),
            suppressWhenPaneFocused: true,
            runtimeID: "claude:RUN",
            eventToken: "4"
        )
    }

    @Test("the body the rules chose is what the row carries")
    func deliver_usesTheBodyTheRulesChose() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(kind: .finished, body: "ran the tests", tab: tab.id, pane: pane),
                tab: tab,
                session: session
            )

            let entry = try #require(history.entries.first)
            #expect(entry.body == "ran the tests")
            #expect(entry.kind == .agentFinished)
            #expect(entry.paneID == pane)
            // With no turn handed over, the history keeps the prompt alone.
            #expect(entry.event == .turnFinished(agent: .claude, turn: nil, prompt: "ran the tests", promptKind: .text, reply: nil))
        }
    }

    @Test("a notification with nothing to quote falls back to naming the agent")
    func deliver_withoutABody_namesTheAgent() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(kind: .needsInput, body: nil, tab: tab.id, pane: pane),
                tab: tab,
                session: session
            )

            // Both agents set a generic terminal title, so the localized
            // sentence naming the agent is the only thing left to say.
            let entry = try #require(history.entries.first)
            #expect(entry.body == "Claude Code is waiting for a response")
            #expect(entry.kind == .agentNeedsInput)
        }
    }

    /// The wait as its record states it, with the words the projection's
    /// body was cut from or stood in for.
    struct WaitCase: Sendable, CustomTestStringConvertible {
        let body: String?
        let wait: PromptWait?
        let filed: String

        var testDescription: String {
            filed
        }
    }

    @Test(
        "a wait is filed as its record states it, not as the cut or stand-in body reads",
        arguments: [
            // The body cut to a banner's length; the record has the whole path.
            WaitCase(
                body: "Write: /Users/me/repositories/limpid/.claude/worktrees/supervision-ui/Limpid/Core/Domain/Prom…",
                wait: PromptWait(
                    detail: "Write: /Users/me/repositories/limpid/.claude/worktrees/supervision-ui/Limpid/Core/Domain/PromptWait.swift",
                    kind: .approval,
                    tool: "Write"
                ),
                filed: "Waiting for approval: PromptWait.swift"
            ),
            // No words: the projection stands in with the last prompt.
            WaitCase(
                body: "fix the failing test",
                wait: PromptWait(detail: nil, kind: .approval, tool: "Bash"),
                filed: "Waiting for approval: Bash"
            ),
            WaitCase(
                body: "fix the failing test",
                wait: PromptWait(detail: nil, kind: .question, tool: nil),
                filed: "Claude Code is asking a question"
            ),
            // A question whose words read like a tool's request.
            WaitCase(
                body: "Read: which file first?",
                wait: PromptWait(detail: "Read: which file first?", kind: .question, tool: nil),
                filed: "Question: Read: which file first?"
            ),
            // A wait we cannot name, in its own words.
            WaitCase(
                body: "Allow network access?",
                wait: PromptWait(detail: "Allow network access?"),
                filed: "Needs response: Allow network access?"
            ),
            // A run not known here: the body as it came, never read for its kind.
            WaitCase(body: "Write: /repo/notes.txt", wait: nil, filed: "Write: /repo/notes.txt")
        ]
    )
    func deliver_aWait_isWordedFromItsRecord(_ example: WaitCase) throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(kind: .needsInput, body: example.body, tab: tab.id, pane: pane),
                wait: example.wait,
                tab: tab,
                session: session
            )

            #expect(history.entries.first?.body == example.filed)
        }
    }

    @Test("a notification is titled by what happened, and the workspace is its subtitle")
    func deliver_inAProject_titlesByWhatHappened() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
            let tab = session.openTab(container: .project(project.id))
            let pane = try #require(tab.splitTree.allLeafIDs().first)

            try emitter(history).deliver(
                payload(kind: .needsInput, body: nil, tab: tab.id, pane: pane),
                wait: PromptWait(detail: "Bash: swift test", kind: .approval, tool: "Bash"),
                tab: tab,
                session: session
            )
            let wait = try #require(history.entries.first)
            #expect(wait.title == "Claude Code is waiting for approval")
            #expect(wait.containerLabel == "limpid")

            try emitter(history).deliver(
                payload(kind: .finished, body: "ran the tests", tab: tab.id, pane: pane),
                tab: tab,
                session: session
            )
            let finished = try #require(history.entries.first)
            #expect(finished.title == "Claude Code finished a turn")
            #expect(AgentNotificationEmitter.subtitle(forContainerLabel: "limpid") == "limpid")
            #expect(AgentNotificationEmitter.subtitle(forContainerLabel: "") == nil)
        }
    }

    @Test("a failure is filed without interrupting")
    func deliver_failureDoesNotPresentABanner() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()

            try emitter(history).deliver(
                payload(
                    kind: .failed,
                    body: "rate limited",
                    tab: tab.id,
                    pane: pane,
                    presentsBanner: false
                ),
                tab: tab,
                session: session
            )

            // The agent's own dialog is already on screen; the row is so the
            // failure is still findable once that dialog is gone.
            let entry = try #require(history.entries.first)
            #expect(entry.kind == .agentError)
            #expect(entry.body == "rate limited")
            #expect(entry.event == .stopped(agent: .claude, reason: "rate limited"))
        }
    }

    @Test("a wait is kept as the wait it was and what it named, not the banner's sentence")
    func deliver_aWait_keepsItsEvent() throws {
        try withTempDir { root in
            let history = NotificationHistoryStore(directory: root)
            let (session, tab, pane) = WorkspaceSessionFixture.withLooseTab()
            @MainActor
            func filed(_ wait: PromptWait?, body: String? = nil) throws -> NotificationEvent? {
                try emitter(history).deliver(
                    payload(kind: .needsInput, body: body, tab: tab.id, pane: pane),
                    wait: wait,
                    tab: tab,
                    session: session
                )
                return history.entries.first?.event
            }
            let approval = try filed(PromptWait(detail: "Write: /repo/notes.txt", kind: .approval, tool: "Write"))
            #expect(approval == .wait(agent: .claude, wait: .approval, fact: "notes.txt"))
            let question = try filed(PromptWait(detail: "Which color?", kind: .question, tool: nil))
            #expect(question == .wait(agent: .claude, wait: .question, fact: "Which color?"))
            // A run not known here: its words, read as a record's are.
            let unknown = try filed(nil, body: "Bash: swift test")
            #expect(unknown == .wait(agent: .claude, wait: .approval, fact: "swift test"))
            let silent = try filed(nil)
            #expect(silent == .wait(agent: .claude, wait: .response, fact: nil))
        }
    }
}
