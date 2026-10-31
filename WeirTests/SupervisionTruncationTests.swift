// SupervisionTruncationTests.swift
// Weir — the one rule for where the supervision window cuts a line, and the models that name their lines' kinds.

import Foundation
import Testing
@testable import Weir

struct SupervisionTruncationTests {
    /// Prose and names keep their start; a path, a subject, and a branch keep
    /// their two ends; a breadcrumb and a title that reads as a path keep their
    /// end.
    @Test func eachKindOfLine_isCutAtItsOwnEdge() {
        let edges: [(SupervisionTruncation, SupervisionTruncation.Edge)] = [
            (.sentence, .tail),
            (.name, .tail),
            (.path, .middle),
            (.subject, .middle),
            (.branch, .middle),
            (.breadcrumb, .head),
            (.pathTitle, .head)
        ]
        for (content, edge) in edges {
            #expect(content.edge == edge, "\(content)")
        }
    }

    /// A menu cannot cut its own lines, so a long name is cut by count:
    /// its first 32 characters and an ellipsis. A short one is left whole.
    @Test func aNameInAMenu_isCutTo32CharactersAndAnEllipsis() {
        let long = "Review every libghostty patch on the fork and list the ones upstream took"
        let cut = SupervisionTruncation.menuName(long)
        #expect(cut == String(long.prefix(32)) + "…")
        #expect(cut.count == SupervisionTruncation.menuNameLimit + 1)
        #expect(SupervisionTruncation.menuName("Fix tests") == "Fix tests")
        let exact = String(repeating: "a", count: SupervisionTruncation.menuNameLimit)
        #expect(SupervisionTruncation.menuName(exact) == exact, "32 fits whole")
        #expect(SupervisionTruncation.end("Fix the flaky tests", keeping: 8) == "Fix the…", "no space before the ellipsis")
    }

    /// A conversation's menu name cuts its title before its number, so two
    /// of one long title still read apart; the whole name is kept for the
    /// tooltip and VoiceOver.
    @Test func aConversationsMenuName_cutsItsTitle_andKeepsItsNumber() {
        let title = "Review every libghostty patch on the fork and list the ones upstream took"
        let choice = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("a"),
            title: title,
            ordinal: 2,
            unviewedCount: 0
        )
        let english = Locale(identifier: "en")
        #expect(ConversationText.menuName(choice, locale: english) == String(title.prefix(32)) + "… #2")
        #expect(ConversationText.name(choice, locale: english) == "\(title) #2")
        #expect(ConversationText.spokenName(choice, locale: english) == "Claude, \(title) #2")
        let short = ConversationChoice(
            conversation: TurnSummaryFixture.conversation("b"),
            title: "Fix tests",
            ordinal: nil,
            unviewedCount: 0
        )
        #expect(ConversationText.menuName(short, locale: english) == "Fix tests")
    }

    @Test(arguments: [
        "…/sample-reviews/demo-repos/alpha",
        ".../repos/beta",
        "/usr/local",
        "/Users/me/weir src",
        "~",
        "~/notes",
        " ~/padded",
        "me@mac: ~/weir",
        "me@mac: /Users/me/weir"
    ])
    func aTitleShapedLikeAPath_isCutAtItsHead(_ title: String) {
        #expect(SupervisionTruncation.isPathTitle(title))
        #expect(SupervisionTruncation.title(title) == .pathTitle)
    }

    @Test(arguments: [
        "zsh",
        "Claude Code",
        "vim ~/notes",
        "npm run build",
        "alpha/beta",
        "…weir",
        "~notes",
        "/init",
        "/review-pr 123 fix",
        "Question: which one?",
        ""
    ])
    func aTitleThatIsANameOrACommand_isCutAtItsEnd(_ title: String) {
        #expect(!SupervisionTruncation.isPathTitle(title))
        #expect(SupervisionTruncation.title(title) == .name)
    }

    @Test func aRowsFact_namingAFileOrACommand_keepsBothEnds_andProseItsStart() {
        let subjects: [SessionRowFact.Fact] = [
            .approval("npm test"),
            .running("Write: /Users/me/weir/notes.txt"),
            .prompt(PromptWait(detail: "Write: /Users/me/weir/notes.txt")),
            .prompt(.unclassified(detail: "Overwrite notes.txt?"))
        ]
        #expect(subjects.allSatisfy { SupervisionTruncation.fact($0) == .subject })
        let prose: [SessionRowFact.Fact] = [
            .question("Which color should the button be?"),
            .approval(nil),
            .running(nil),
            .prompt(.question(detail: "Which file?")),
            .prompt(.unclassified(detail: nil)),
            .compacting,
            .idle,
            .commits(3)
        ]
        #expect(prose.allSatisfy { SupervisionTruncation.fact($0) == .sentence })
    }

    // MARK: - The models that name their lines' kinds

    @Test func aNeedsAttentionRow_keepsTheFileItWaitsOn_andAQuestionsStart() {
        var queue = AttentionQueue()
        let waits = [
            PromptWait(detail: "Edit: /repo/Sources/App.swift"),
            PromptWait(detail: nil),
            PromptWait.question(detail: "Which branch?")
        ]
        for (offset, wait) in waits.enumerated() {
            queue.insert(
                id: .prompt(EpisodeKey(origin: .runtime("r\(offset)"), episodeToken: "1")),
                kind: .prompt(wait),
                subject: .runtime(id: "r\(offset)", provider: .claude, paneID: UUID(), tabID: nil, projectID: nil),
                arrivedAt: Date(timeIntervalSince1970: TimeInterval(offset))
            )
        }
        let model = NeedsAttentionListModel(
            items: queue.items,
            names: { _ in .init(title: "alpha", place: "alpha") },
            request: { _ in nil },
            windowProjectID: nil,
            locale: Locale(identifier: "en")
        )
        #expect(model.rows.map(\.factTruncation) == [.subject, .sentence, .sentence])
    }

    @MainActor
    @Test func anAllProjectsCard_isCutAsItsRowsFactIs() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "weir")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: "Write: /Users/me/weir/notes.txt")),
            subject: .runtime(id: "r", provider: .claude, paneID: paneID, tabID: tab.id, projectID: project.id),
            arrivedAt: Date(timeIntervalSince1970: 0)
        )
        let registry = WindowRegistry(primary: session.primarySelection)
        registry.presenter = RecordingWindowPresenter()
        let cards = AllProjectsModel.cards(AllProjectsModel.Sources(
            session: session, window: session.primaryWindowID, registry: registry, queue: queue,
            runtimes: [], approvals: ApprovalLedger(), pullRequest: { _ in nil }, gitFacts: { _ in nil },
            locale: Locale(identifier: "en")
        ))
        #expect(try #require(cards.first).factTruncation == .subject)
    }
}

/// A name set into a sentence is cut in its middle, by count, before the
/// line is laid out (`SupervisionTruncation.middle`).
struct SupervisionTruncationMiddleTests {
    @Test func aNameWithinTheLimit_isLeftWhole() {
        #expect(SupervisionTruncation.middle("feature/login", limit: 40) == "feature/login")
        #expect(SupervisionTruncation.middle(String(repeating: "a", count: 40), limit: 40).count == 40)
    }

    @Test func aLongerName_keepsItsStartAndEnd_atTheLimit() {
        let name = "nek0der/feature/" + String(repeating: "x", count: 60) + "/1021-1"
        let cut = SupervisionTruncation.middle(name, limit: 40)
        #expect(cut.count == 40)
        #expect(cut.hasPrefix("nek0der/feature/"))
        #expect(cut.hasSuffix("/1021-1"))
        #expect(cut.contains("…"))
    }

    @Test func aLimitTooSmallToCut_leavesTheName() {
        #expect(SupervisionTruncation.middle("feature/login", limit: 1) == "feature/login")
        #expect(SupervisionTruncation.middle("", limit: 0).isEmpty)
    }
}
