// NotificationBannerTests.swift
// Weir — what a banner says, and which banners held while the Mac slept are posted on waking.

import Foundation
import Testing
@testable import Weir

@Suite("Notification banners")
struct NotificationBannerTests {
    @Test func bannersHeldAfterWaking_postOneOrASummary_andLeaveOutWhatWasTakenBack() {
        var held = HeldBanners<String>()
        #expect(isNothing(held.outcome))

        held.hold("first", identifier: "a")
        if case let .single(banner) = held.outcome {
            #expect(banner == "first")
        } else {
            Issue.record("one banner is posted as it is")
        }

        held.hold("second", identifier: "b")
        if case .summary = held.outcome {} else {
            Issue.record("two make a summary")
        }

        // A request answered or timed out meanwhile is never posted.
        held.drop(identifier: "b")
        if case let .single(banner) = held.outcome {
            #expect(banner == "first")
        } else {
            Issue.record("the one left is posted as it is")
        }
        held.drop(identifier: "a")
        #expect(isNothing(held.outcome))
    }

    private func isNothing(_ outcome: HeldBanners<String>.Outcome) -> Bool {
        if case .nothing = outcome {
            true
        } else {
            false
        }
    }

    @Test func theWakeSummary_countsByKind() throws {
        let english = Locale(identifier: "en")
        #expect(AttentionSummaryText.make(AttentionCounts(), locale: english) == nil)

        // A wait at the agent's prompt we cannot name is counted as its row names it.
        let counts = AttentionCounts(approvals: 1, questions: 0, prompts: 1, stops: 0, unread: 3)
        let text = try #require(AttentionSummaryText.make(counts, locale: english))
        #expect(text.title == "Needs Attention · 5")
        #expect(text.body == "1 Approval · 1 Response · 3 Unread")
        let japanese = try #require(AttentionSummaryText.make(counts, locale: Locale(identifier: "ja")))
        #expect(japanese.body.contains("応答 1"))
    }

    @Test func aRequestsBanner_saysWhereAndWhat() {
        let english = Locale(identifier: "en")
        func request(summary: String?, question: String?, tool: String = "Bash") -> ApprovalPresentation {
            ApprovalPresentation.test(
                toolName: tool,
                summary: summary,
                questions: question.map { [ApprovalQuestion(header: nil, prompt: $0, options: [], isMultiSelect: false)] } ?? []
            )
        }

        let command = RequestBannerText.make(
            for: request(summary: "make test", question: nil),
            containerLabel: "weir / main",
            locale: english
        )
        // Titled by what happened; where it happened is the subtitle.
        #expect(command.title == "Claude Code is waiting for approval")
        #expect(command.subtitle == "weir / main")
        #expect(command.body == "Waiting for approval: make test")

        let question = RequestBannerText.make(for: request(summary: nil, question: "Which color?"), containerLabel: nil, locale: english)
        #expect(question.body == "Which color?")
        #expect(question.title == "Claude Code is asking a question")
        #expect(question.subtitle == nil)
        let placedQuestion = RequestBannerText.make(
            for: request(summary: nil, question: "Which color?"),
            containerLabel: "weir / feat-x",
            locale: english
        )
        #expect(placedQuestion.title == "Claude Code is asking a question")
        #expect(placedQuestion.subtitle == "weir / feat-x")

        let bare = RequestBannerText.make(for: request(summary: "", question: nil), containerLabel: "", locale: english)
        #expect(bare.body == "Waiting for approval: Bash")
        #expect(bare.title == "Claude Code is waiting for approval")
        #expect(bare.subtitle == nil)

        // Shortened as a wait Weir does not hold is: a command on one
        // line, a path as its file's name.
        let multiline = RequestBannerText.make(
            for: request(summary: "swift test\n  --parallel", question: nil),
            containerLabel: "x",
            locale: english
        )
        #expect(multiline.body == "Waiting for approval: swift test --parallel")
        let file = RequestBannerText.make(
            for: request(summary: "/Users/me/repo/notes.txt", question: nil, tool: "Write"),
            containerLabel: "x",
            locale: english
        )
        #expect(file.body == "Waiting for approval: notes.txt")

        // The history keeps what the banner names, as values.
        #expect(RequestBannerText.event(for: request(summary: "/Users/me/repo/notes.txt", question: nil, tool: "Write"))
            == .wait(agent: .claude, wait: .approval, fact: "notes.txt"))
        #expect(RequestBannerText.event(for: request(summary: "", question: nil))
            == .wait(agent: .claude, wait: .approval, fact: "Bash"))
        #expect(RequestBannerText.event(for: request(summary: nil, question: "Which color?"))
            == .wait(agent: .claude, wait: .question, fact: "Which color?"))
    }
}
