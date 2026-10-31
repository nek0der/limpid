// ConversationTitleRuleTests.swift
// Weir — which of a conversation's titles names it: the tab's rename, the provider's, the recorded one, or its first prompt.

import Foundation
import Testing
@testable import Weir

struct ConversationTitleRuleTests {
    private static func title(
        tabName: String? = nil,
        remembered: String? = nil,
        live: String? = nil,
        recorded: String? = nil,
        firstPrompt: TurnPrompt? = nil
    ) -> String? {
        ConversationTitleRule.title(
            tabName: tabName,
            rememberedTabName: remembered,
            liveTitle: live,
            recordedTitle: recorded,
            firstPrompt: firstPrompt
        )
    }

    @Test func title_tabOverride_winsOverEverything() {
        let title = Self.title(
            tabName: "Payments",
            remembered: "Billing",
            live: "Live",
            recorded: "Recorded",
            firstPrompt: TurnPrompt(head: "Add tests")
        )
        #expect(title == "Payments")
    }

    /// The name the person gave a tab the conversation ran in still names
    /// it once that tab is gone, over every title a program gave it.
    @Test func title_rememberedTabName_winsOverProviderTitles() {
        #expect(Self.title(remembered: "Payments", live: "Live", recorded: "Recorded") == "Payments")
    }

    @Test func title_liveTitle_winsOverRecorded() {
        #expect(Self.title(live: "Live", recorded: "Recorded") == "Live")
    }

    /// The live title the panel is handed is the one the Rust side names the
    /// tab and each turn by (`conversation_title` in
    /// `rust/weir-agent-core/src/title.rs`), read through the same
    /// resolver: the session's name, else the generated title, cleaned, and
    /// never the opening prompt. So the panel never names a conversation
    /// one way while its tab and its turns say another.
    @Test(arguments: [
        LiveTitles(session: " Session ", generated: "Generated", expected: "Session"),
        LiveTitles(session: " \n ", generated: "Generated", expected: "Generated"),
        LiveTitles(session: nil, generated: "Generated", expected: "Generated"),
        LiveTitles(session: "Fix\nflaky tests", generated: nil, expected: "Fix flaky tests"),
        LiveTitles(session: nil, generated: nil, expected: nil)
    ])
    func liveTitle_followsTheRustConversationTitle(_ fixture: LiveTitles) {
        let live = WeirRustTitleResolver.resolve(
            providerSessionTitle: fixture.session,
            providerGeneratedTitle: fixture.generated,
            firstPrompt: nil
        )
        #expect(live == fixture.expected)
    }

    /// One case of the shared order: the provider's two live titles and
    /// the title they name the conversation by.
    struct LiveTitles: Sendable, CustomTestStringConvertible {
        let session: String?
        let generated: String?
        let expected: String?

        var testDescription: String {
            "session \(session.debugDescription), generated \(generated.debugDescription)"
        }
    }

    @Test func title_noLiveTitle_usesLatestRecordedTitle() {
        #expect(Self.title(recorded: "Recorded", firstPrompt: TurnPrompt(head: "Add tests")) == "Recorded")
    }

    @Test func title_nothingRecorded_usesFirstPromptInstruction() {
        #expect(Self.title(firstPrompt: TurnPrompt(head: "  Add tests  ")) == "Add tests")
        // The harness's words are no name: its kind would name every
        // conversation a background task woke alike.
        #expect(Self.title(firstPrompt: TurnPrompt(kind: .backgroundTask, head: "<task-notification>")) == nil)
        #expect(Self.title(firstPrompt: TurnPrompt(head: nil)) == nil)
        #expect(Self.title() == nil)
    }

    /// A goal's objective is the person's words, which Codex's turns for it
    /// begin from in place of a prompt.
    @Test func title_goalsObjective_namesTheConversation() {
        #expect(Self.title(firstPrompt: TurnPrompt(kind: .goal, head: "Ship the release")) == "Ship the release")
    }

    @Test func title_whitespaceOnly_isIgnored() {
        let title = Self.title(tabName: "  ", remembered: " ", live: "\n", recorded: " \t", firstPrompt: TurnPrompt(head: "Fix it"))
        #expect(title == "Fix it")
    }

    @Test func title_multiline_keepsFirstLine() {
        #expect(Self.title(tabName: "Review the fork\nand its patches") == "Review the fork")
        #expect(Self.title(firstPrompt: TurnPrompt(head: "\n  Add tests  \r\nfor the store")) == "Add tests")
    }
}
