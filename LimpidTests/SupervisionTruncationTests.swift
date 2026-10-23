// SupervisionTruncationTests.swift
// Limpid — the one rule for where the supervision window cuts a line, and the models that name their lines' kinds.

import Foundation
import Testing
@testable import Limpid

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

    @Test(arguments: [
        "…/sample-reviews/demo-repos/alpha",
        ".../repos/beta",
        "/usr/local",
        "/Users/me/limpid src",
        "~",
        "~/notes",
        " ~/padded",
        "me@mac: ~/limpid",
        "me@mac: /Users/me/limpid"
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
        "…limpid",
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
            .running("Write: /Users/me/limpid/notes.txt"),
            .prompt(PromptWait(detail: "Write: /Users/me/limpid/notes.txt")),
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
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        var queue = AttentionQueue()
        queue.insert(
            id: .prompt(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .prompt(PromptWait(detail: "Write: /Users/me/limpid/notes.txt")),
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
