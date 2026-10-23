// ConversationNameTests.swift
// Limpid — which conversation names a tab's row, how the name follows it while it runs, and that it is kept.

import Foundation
import Testing
@testable import Limpid

struct ConversationNameTests {
    private static let claudePane = UUID()
    private static let codexPane = UUID()

    private static func badge(
        conversationID: String? = nil,
        sessionTitle: String? = nil,
        generatedTitle: String? = nil,
        firstPrompt: String? = nil,
        startedAt seconds: TimeInterval? = 0
    ) -> AgentBadge {
        AgentBadge(
            state: .running,
            updatedAt: Date(),
            firstPrompt: firstPrompt,
            conversationID: conversationID,
            providerSessionTitle: sessionTitle,
            providerGeneratedTitle: generatedTitle,
            sessionStartedAt: seconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Claude has session titles; Codex is named by its opening prompt.
    private static func hasSessionTitles(_ kind: AgentKind) -> Bool {
        kind == .claude
    }

    private static func remembered(
        _ current: ConversationName?,
        _ badges: [AgentKind: [UUID: AgentBadge]]
    ) -> ConversationName? {
        // Through the tab, which binds the rule to the pane header's title.
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = current
        tab.agentBadges = badges
        tab.rememberConversationName(hasSessionTitles: hasSessionTitles)
        return tab.conversationName
    }

    @Test func aConversation_isNamedByItsCLITitle_elseItsFirstPrompt() {
        let prompt = Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(conversationID: "c", firstPrompt: "Add tests")]])
        #expect(prompt?.name == "Add tests")

        let titled = Self.remembered(prompt, [.claude: [Self.claudePane: Self.badge(
            conversationID: "c",
            generatedTitle: "Testing the store",
            firstPrompt: "Add tests"
        )]])
        // The title the CLI gave it later follows, as the pane header does.
        #expect(titled?.name == "Testing the store")
        #expect(titled?.conversationID == "c")
    }

    @Test func aClaudeRunBeforeItsSessionIsKnown_namesNothingYet() {
        #expect(Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(firstPrompt: "Add tests")]]) == nil)
    }

    @Test func theName_isKept_whenTheConversationEnds() {
        let named = Self.remembered(nil, [.codex: [Self.codexPane: Self.badge(firstPrompt: "Fix the build")]])
        #expect(Self.remembered(named, [:]) == named)
    }

    @Test func aLaterConversation_doesNotRenameTheTab() {
        let first = Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(conversationID: "a", firstPrompt: "First task")]])
        // A new conversation in the same pane, after the first ended.
        let next = Self.remembered(first, [.claude: [Self.claudePane: Self.badge(
            conversationID: "b",
            firstPrompt: "Second task",
            startedAt: 60
        )]])
        #expect(next?.name == "First task")

        // A new Codex session in the same pane has no id, but a new start.
        let codex = Self.remembered(nil, [.codex: [Self.codexPane: Self.badge(firstPrompt: "Codex task")]])
        let again = Self.remembered(codex, [.codex: [Self.codexPane: Self.badge(firstPrompt: "Another", startedAt: 60)]])
        #expect(again?.name == "Codex task")
    }

    @Test func aConversationWithNeitherIDNorStart_isNeverTakenForTheNext() {
        let first = Self.remembered(nil, [.codex: [Self.codexPane: Self.badge(firstPrompt: "First", startedAt: nil)]])
        let next = Self.remembered(first, [.codex: [Self.codexPane: Self.badge(firstPrompt: "Second", startedAt: nil)]])
        #expect(first?.name == "First")
        #expect(next?.name == "First")
    }

    @Test func onlyTheRememberedConversation_isAskedForATitle_inOrder() {
        let current = ConversationName(
            name: "First task",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "a",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let later = UUID()
        let observed = [
            ConversationName.Observed(provider: .claude, paneID: later, conversationID: "a", startedAt: Date(timeIntervalSince1970: 20)),
            ConversationName.Observed(
                provider: .codex,
                paneID: Self.codexPane,
                conversationID: nil,
                startedAt: Date(timeIntervalSince1970: 5)
            ),
            ConversationName.Observed(
                provider: .claude,
                paneID: Self.claudePane,
                conversationID: "a",
                startedAt: Date(timeIntervalSince1970: 10)
            )
        ]
        var asked: [UUID] = []

        let next = ConversationName.remembered(current, observed: observed) { session in
            asked.append(session.paneID)
            return "Title in \(session.paneID == later ? "later" : "earlier")"
        }

        // The Codex session is another conversation, so it is never asked;
        // of the two panes holding this one, the earlier answers, every time.
        #expect(asked == [Self.claudePane])
        #expect(next?.name == "Title in earlier")
        #expect(next?.paneID == Self.claudePane)
        #expect(ConversationName.remembered(current, observed: observed.reversed()) { _ in "x" }?.paneID == Self.claudePane)
    }

    @Test func anEarliestSessionWithoutATitle_leavesTheNameToTheNext() {
        let untitled = UUID()
        let observed = [
            ConversationName.Observed(provider: .claude, paneID: untitled, conversationID: nil, startedAt: Date(timeIntervalSince1970: 0)),
            ConversationName.Observed(
                provider: .codex,
                paneID: Self.codexPane,
                conversationID: nil,
                startedAt: Date(timeIntervalSince1970: 10)
            )
        ]

        let named = ConversationName.remembered(nil, observed: observed) { session in
            session.paneID == untitled ? nil : "Codex task"
        }

        #expect(named?.name == "Codex task")
        #expect(named?.paneID == Self.codexPane)
        #expect(named?.startedAt == Date(timeIntervalSince1970: 10))
    }

    @Test func theRememberedConversation_answersFromALaterPane_whenTheEarlierHasNoTitle() {
        let current = ConversationName(
            name: "First task",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "a",
            startedAt: Date(timeIntervalSince1970: 0)
        )
        let later = UUID()
        let observed = [
            ConversationName.Observed(
                provider: .claude,
                paneID: Self.claudePane,
                conversationID: "a",
                startedAt: Date(timeIntervalSince1970: 10)
            ),
            ConversationName.Observed(provider: .claude, paneID: later, conversationID: "a", startedAt: Date(timeIntervalSince1970: 20))
        ]

        let next = ConversationName.remembered(current, observed: observed) { session in
            session.paneID == later ? "Renamed" : nil
        }

        #expect(next?.name == "Renamed")
        #expect(next?.paneID == later)
        // Still ordered by when the conversation first started.
        #expect(next?.startedAt == current.startedAt)
    }

    @Test func aResumedConversation_keepsFollowingItsTitle() {
        let first = Self.remembered(nil, [.claude: [Self.claudePane: Self.badge(conversationID: "a", firstPrompt: "First task")]])
        // `claude --continue` starts a new session of the same conversation.
        let resumed = Self.remembered(first, [.claude: [UUID(): Self.badge(
            conversationID: "a",
            sessionTitle: "Renamed by /rename",
            firstPrompt: "First task",
            startedAt: 90
        )]])
        #expect(resumed?.name == "Renamed by /rename")
        // Still ordered by when the conversation first started.
        #expect(resumed?.startedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func twoConversationsAtOnce_nameTheTabByTheEarlier() {
        let named = Self.remembered(nil, [
            .claude: [Self.claudePane: Self.badge(conversationID: "c", firstPrompt: "Later", startedAt: 20)],
            .codex: [Self.codexPane: Self.badge(firstPrompt: "Earlier", startedAt: 10)]
        ])
        #expect(named?.name == "Earlier")
    }

    @Test func aTab_keepsItsName_throughTheSnapshot() throws {
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = ConversationName(
            name: "Add tests",
            provider: .codex,
            paneID: Self.codexPane,
            conversationID: nil,
            startedAt: Date(timeIntervalSince1970: 0)
        )

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONEncoder().encode(tab))

        #expect(decoded.conversationName == tab.conversationName)
    }

    /// Forward compatibility: the tab's decoder passes over a key it does
    /// not know and keeps the rest. This is what lets a file with a key
    /// from a later build open here; whether a build from before the name
    /// does the same depends on that build's decoder, which this test
    /// cannot run. Such a build would write the session back without the
    /// name.
    @Test func aTab_withAKeyItDoesNotKnow_stillDecodes_andKeepsItsName() throws {
        var tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        tab.conversationName = ConversationName(
            name: "Add tests",
            provider: .claude,
            paneID: Self.claudePane,
            conversationID: "c",
            startedAt: nil
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        object["aLaterField"] = ["name": "from a newer build"]

        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(decoded.id == tab.id)
        #expect(decoded.conversationName == tab.conversationName)
    }

    @Test func aTabFromBeforeTheName_orWithAProviderThisBuildDoesNotKnow_stillDecodes() throws {
        let tab = Tab.newWithSinglePane(title: "zsh", container: .loose).tab
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(tab)) as? [String: Any])
        #expect(object["conversationName"] == nil)
        #expect(try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object)).conversationName == nil)

        object["conversationName"] = ["name": "Add tests", "provider": "gemini", "paneID": UUID().uuidString]
        let decoded = try JSONDecoder().decode(Tab.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.conversationName == nil)
        #expect(decoded.id == tab.id)
    }

    /// Which providers name their sessions, which decides what names a
    /// row and a pane header.
    @Test func providerRegistry_sessionTitleCapabilityMatchesProviders() {
        #expect(AgentProviderRegistry.hasSessionTitles(.claude))
        #expect(!AgentProviderRegistry.hasSessionTitles(.codex))
    }
}
