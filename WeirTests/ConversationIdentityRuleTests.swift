// ConversationIdentityRuleTests.swift
// Weir — each active conversation keeps its identity color while it stays active, and a new one takes the lowest free color.

import Foundation
import Testing
@testable import Weir

struct ConversationIdentityRuleTests {
    private static func key(_ id: String) -> ConversationKey {
        TurnSummaryFixture.conversation(id)
    }

    private let first = Self.key("a")
    private let second = Self.key("b")
    private let third = Self.key("c")
    private let fourth = Self.key("d")

    @Test func assign_singleActive_isEmpty() {
        #expect(ConversationIdentityRule.assign(active: [first], previous: [:], paletteCount: 6).isEmpty)
        #expect(ConversationIdentityRule.assign(active: [], previous: [first: 2], paletteCount: 6).isEmpty)
    }

    @Test func assign_newConversations_takeLowestFreeIndexInCreationOrder() {
        let assigned = ConversationIdentityRule.assign(active: [first, second, third], previous: [:], paletteCount: 6)
        #expect(assigned == [first: 0, second: 1, third: 2])
    }

    @Test func assign_keepsPreviousIndex_whenOthersEnd() {
        let previous = [first: 0, second: 1, third: 2]
        let assigned = ConversationIdentityRule.assign(active: [first, third], previous: previous, paletteCount: 6)
        #expect(assigned == [first: 0, third: 2])
    }

    /// The index of a conversation no longer active is free again: the
    /// next new one takes it rather than the next unused.
    @Test func assign_releasesIndex_ofInactiveConversation() {
        let previous = [first: 0, second: 1]
        let assigned = ConversationIdentityRule.assign(active: [first, third], previous: previous, paletteCount: 6)
        #expect(assigned[second] == nil)
        #expect(assigned == [first: 0, third: 1])
    }

    @Test func assign_reusesReleasedIndex_forNextConversation() {
        let previous = [first: 0, second: 1, third: 2]
        let assigned = ConversationIdentityRule.assign(active: [first, third, fourth], previous: previous, paletteCount: 6)
        #expect(assigned == [first: 0, third: 2, fourth: 1])
    }

    @Test func assign_paletteFull_reusesLeastUsedIndex() {
        let keys = (0..<8).map { Self.key("k\($0)") }
        let assigned = ConversationIdentityRule.assign(active: keys, previous: [:], paletteCount: 3)
        // 0, 1, 2 fill the palette; then the least used, lowest first.
        #expect(keys.map { assigned[$0] } == [0, 1, 2, 0, 1, 2, 0, 1])
        // With 0 used twice and 1 and 2 once, the next takes 1.
        let uneven = ConversationIdentityRule.assign(
            active: [first, second, third, fourth],
            previous: [first: 0, second: 0, third: 2],
            paletteCount: 3
        )
        #expect(uneven[fourth] == 1)
    }

    /// A conversation holds a color while it runs here or has turns to
    /// read, in the agents' order; one ended with every turn viewed does
    /// not.
    @Test func activeConversations_runningOrUnviewed_inAgentsOrder() throws {
        func turn(_ conversation: String) throws -> TurnSummary {
            var extras = TurnSummaryFixture.Extras()
            extras.conversationID = conversation
            return try ChangesPanelFixture.turn(1, extras: extras)
        }
        let viewed = try turn("a")
        let unviewed = try turn("b")
        let runningViewed = try turn("c")
        let agents = ChangesPanelFixture.agents([viewed, unviewed, runningViewed])
        let lines = [ChangesPanelFixture.line(through: viewed).line, ChangesPanelFixture.line(through: runningViewed).line]
        let waiting = Self.key("d")
        var input = ChangesPanelFixture.input(agents, lines: lines, running: [waiting, runningViewed.conversation])
        input.agents.append(ChangesPanelModel.Agent(conversation: waiting, turns: []))
        #expect(ChangesPanelModel.activeConversations(input) == [unviewed.conversation, runningViewed.conversation, waiting])
    }

    /// The filter's entries carry the color the panel handed out.
    @Test func choices_carryTheirIdentity() throws {
        var extras = TurnSummaryFixture.Extras()
        extras.conversationID = "b"
        let turns = try [ChangesPanelFixture.turn(1), ChangesPanelFixture.turn(1, extras: extras)]
        var input = ChangesPanelFixture.input(ChangesPanelFixture.agents(turns))
        input.identities = [turns[0].conversation: 3, turns[1].conversation: 0]
        let choices = ChangesPanelModel.conversations(input)
        #expect(choices.map(\.identity) == [3, 0])
    }

    /// A key that differs from the last read's at every call, so each
    /// read hands the colors out again over the active set it is given.
    private static func key(_ revision: Int) -> ConversationIdentityStore.Key {
        ConversationIdentityStore.Key(
            root: "/repo",
            historyRevision: revision,
            viewedLinesRevision: 0,
            running: [],
            restored: [],
            pathGeneration: 0
        )
    }

    @MainActor
    @Test func identities_sameContainer_keepsAssignmentsAcrossCalls() {
        let store = ActionStoresFixture().conversationIdentities
        let container = ContainerID.project(UUID())
        let read = { (revision: Int, active: [ConversationKey]) in
            store.identities(for: container, key: Self.key(revision)) { active }
        }
        #expect(read(1, [first, second, third]) == [first: 0, second: 1, third: 2])
        #expect(read(2, [second, third]) == [second: 1, third: 2])
        #expect(read(3, [second, third, fourth]) == [second: 1, third: 2, fourth: 0])
    }

    @MainActor
    @Test func identities_otherContainer_isIndependent() {
        let store = ActionStoresFixture().conversationIdentities
        let container = ContainerID.project(UUID())
        let other = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let read = { (container: ContainerID, revision: Int, active: [ConversationKey]) in
            store.identities(for: container, key: Self.key(revision)) { active }
        }
        _ = read(container, 1, [first, second])
        #expect(read(other, 1, [second, third]) == [second: 0, third: 1])
        #expect(read(container, 2, [first, second]) == [first: 0, second: 1])
    }

    /// A read with the key of the last read hands back what it handed out
    /// without finding the active conversations again: the strip reads the
    /// colors on every word an agent reports.
    @MainActor
    @Test func identities_sameKey_doesNotDeriveAgain() {
        let store = ActionStoresFixture().conversationIdentities
        let container = ContainerID.project(UUID())
        var asked = 0
        let active = { () -> [ConversationKey] in
            asked += 1
            return [first, second]
        }
        let read = store.identities(for: container, key: Self.key(1), active: active)
        #expect(store.identities(for: container, key: Self.key(1), active: active) == read)
        #expect(asked == 1)
        #expect(store.derivationCount == 1)
        _ = store.identities(for: container, key: Self.key(2), active: active)
        #expect(asked == 2)
        #expect(store.derivationCount == 2)
    }

    /// Letting go of the path spellings (a project removed) can change
    /// which recorded roots are this worktree's while nothing else moves,
    /// so the next read works the colors out again.
    @MainActor
    @Test func identities_pathGenerationChange_derivesAgain() async throws {
        let paths = WorktreePathResolver(resolveLinks: { $0 })
        let fixture = ActionStoresFixture(repositoryRoots: .staged(paths: paths))
        let container = ContainerID.project(fixture.project.id)
        await fixture.repositoryRoots.resolve(fixture.project.rootURL)
        try #require(fixture.repositoryRoots.answer(for: fixture.project.rootURL) != nil)

        _ = fixture.conversationIdentities.identities(in: container)
        _ = fixture.conversationIdentities.identities(in: container)
        #expect(fixture.conversationIdentities.derivationCount == 1)

        paths.forget(["/elsewhere"])
        _ = fixture.conversationIdentities.identities(in: container)
        #expect(fixture.conversationIdentities.derivationCount == 2)
    }

    /// Two projects opened at folders of one repository share its root but
    /// run different panes, so each finds its own active conversations.
    /// Kept apart, a read of one never takes the other's colors away: the
    /// outer project's third conversation keeps its color after its second
    /// ends, however often the inner project is read between.
    @MainActor
    @Test func identities_twoContainersAtOneRoot_keepIndependentAssignments() async throws {
        let repository = WorkspaceSessionFixture.projectRootURL("monorepo")
        // Every folder's top level is the repository's, as Git would say
        // for a subfolder of it.
        let fixture = ActionStoresFixture(
            repositoryRoots: RepositoryRoots(topLevel: { _ in repository }, paths: WorktreePathResolver(resolveLinks: { $0 }))
        )
        let sub = fixture.session.addOrActivateProject(rootURL: repository.appendingPathComponent("packages/app", isDirectory: true))
        let outer = ContainerID.project(fixture.project.id)
        let inner = ContainerID.project(sub.id)
        fixture.session.openTab(container: outer)
        fixture.session.openTab(container: outer)
        fixture.session.openTab(container: inner)
        fixture.session.openTab(container: inner)
        let outerTabs = fixture.session.tabs(in: outer)
        let innerTabs = fixture.session.tabs(in: inner)
        try #require(outerTabs.count == 3 && innerTabs.count == 2)
        func run(_ id: String, in tab: Tab) throws -> AgentRuntimePresentation {
            try AgentRuntimePresentation.test(
                runID: id,
                badge: AgentBadge(state: .running, updatedAt: Date(), conversationID: id),
                paneIDs: [#require(tab.splitTree.allLeafIDs().first)],
                conversation: TurnSummaryFixture.conversation(id)
            )
        }
        let a = try run("a", in: outerTabs[0])
        let b = try run("b", in: outerTabs[1])
        let c = try run("c", in: outerTabs[2])
        let d = try run("d", in: innerTabs[0])
        let e = try run("e", in: innerTabs[1])
        fixture.attention.replaceRuntimes([a, b, c, d, e], kind: .claude)
        await fixture.repositoryRoots.resolve(fixture.project.rootURL)
        await fixture.repositoryRoots.resolve(sub.rootURL)
        try #require(fixture.repositoryRoots.answer(for: sub.rootURL) == .repository(path: repository.path))
        let key = { (id: String) in TurnSummaryFixture.conversation(id) }

        #expect(fixture.conversationIdentities.identities(in: outer) == [key("a"): 0, key("b"): 1, key("c"): 2])
        fixture.attention.replaceRuntimes([a, c, d, e], kind: .claude)
        #expect(fixture.conversationIdentities.identities(in: outer) == [key("a"): 0, key("c"): 2])
        #expect(fixture.conversationIdentities.identities(in: inner) == [key("d"): 0, key("e"): 1])
        #expect(fixture.conversationIdentities.identities(in: outer) == [key("a"): 0, key("c"): 2])
    }

    /// A project closed since keeps nothing in the store: the next read
    /// that works colors out lets its memory go.
    @MainActor
    @Test func identities_closedContainer_isForgotten() async throws {
        let fixture = ActionStoresFixture()
        let sub = fixture.session.addOrActivateProject(rootURL: WorkspaceSessionFixture.projectRootURL("other"))
        let outer = ContainerID.project(fixture.project.id)
        let inner = ContainerID.project(sub.id)
        await fixture.repositoryRoots.resolve(fixture.project.rootURL)
        await fixture.repositoryRoots.resolve(sub.rootURL)
        let store = fixture.conversationIdentities
        _ = store.identities(in: outer)
        _ = store.identities(in: inner)
        try #require(store.keptContainers == [outer, inner])

        _ = fixture.session.removeProject(sub.id)
        fixture.session.openTab(container: outer)
        let tab = try #require(fixture.session.tabs(in: outer).last)
        let run = try AgentRuntimePresentation.test(
            runID: "a",
            badge: AgentBadge(state: .running, updatedAt: Date(), conversationID: "a"),
            paneIDs: [#require(tab.splitTree.allLeafIDs().first)],
            conversation: TurnSummaryFixture.conversation("a")
        )
        fixture.attention.replaceRuntimes([run], kind: .claude)
        _ = store.identities(in: outer)

        #expect(store.keptContainers == [outer])
    }
}
