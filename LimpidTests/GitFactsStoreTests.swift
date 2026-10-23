// GitFactsStoreTests.swift
// Limpid — when the session folders' Git facts are read, and what a reading Git did not answer keeps.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct GitFactsStoreTests {
    private nonisolated static let facts = GitFactsFixture.make(commits: nil, unpushed: nil, uncommitted: 1, base: nil)

    @Test func aReadingOfAll_keepsWhatItRead_andForgetsFoldersNoLongerListed() async {
        let store = GitFactsStore(fetch: { _ in .facts(Self.facts) })
        let project = ContainerID.project(UUID())
        let gone = ContainerID.project(UUID())
        await store.refresh([.init(container: project, workingDirectory: URL(fileURLWithPath: "/a"))], isAll: true)
        await store.refresh(gone, at: URL(fileURLWithPath: "/b"))
        #expect(store.facts(for: gone) == Self.facts)

        await store.refresh([.init(container: project, workingDirectory: URL(fileURLWithPath: "/a"))], isAll: true)
        #expect(store.facts(for: project) == Self.facts)
        #expect(store.facts(for: gone) == nil)
    }

    @Test func comingToTheFront_readsEveryFolder_onlyAsTheAppBecomesActive() async {
        let reads = Recorded(0)
        let store = GitFactsStore(fetch: { _ in
            reads.update { $0 += 1 }
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        let front = Recorded(false)
        // Not in front yet, as at launch: the clock reads nothing.
        store.start(session: session) { front.value }

        // The first coming to the front reads, as every later one does.
        front.value = true
        store.appActivityChanged(isActive: true)
        await pollUntil { store.facts(for: .project(project.id)) != nil }
        #expect(store.facts(for: .project(project.id)) == Self.facts)
        #expect(reads.value == 1)

        // Going to the back and coming to the front again reads again; a
        // report while already in front is no coming back
        // (`startingWhileLimpidIsInFront_readsEveryFolderAtOnce_andOnce`).
        front.value = false
        store.appActivityChanged(isActive: false)
        front.value = true
        store.appActivityChanged(isActive: true)
        await pollUntil { reads.value == 2 }
        #expect(reads.value == 2)
    }

    /// Launched in front, the store reads at once, and the report of being
    /// in front that follows is no coming to the front.
    @Test func startingWhileLimpidIsInFront_readsEveryFolderAtOnce_andOnce() async {
        let reads = Recorded(0)
        let store = GitFactsStore(fetch: { _ in
            reads.update { $0 += 1 }
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        store.start(session: session) { true }
        // `start` reads by itself: launched from Finder, no report follows.
        await pollUntil { store.facts(for: .project(project.id)) != nil }
        #expect(store.facts(for: .project(project.id)) == Self.facts)
        #expect(reads.value == 1)
        store.appActivityChanged(isActive: true)
        // Nothing marks a reading that did not happen: the shortest wait
        // that would let a second one start.
        await pollUntil(timeout: .milliseconds(200)) { reads.value > 1 }
        #expect(reads.value == 1)
    }

    @Test func aReadingAfterThePersonsRead_waitsForIt() async {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .facts(Self.facts)
        })
        let container = ContainerID.project(UUID())
        async let asked = store.read(container, at: URL(fileURLWithPath: "/asked"))
        await pollUntil { log.value == ["start asked"] }
        async let clock: Void = store.refresh(container, at: URL(fileURLWithPath: "/clock"))
        await pollUntil(timeout: .milliseconds(200)) { log.value.count > 1 }
        #expect(log.value == ["start asked"])
        gate.open()
        _ = await (asked, clock)
        #expect(log.value == ["start asked", "end asked", "start clock", "end clock"])
    }

    @Test func aReadingAskedForByThePerson_ignoresTheWait_andSaysWhatGitAnswered() async {
        let answers = Answers([.unanswered, .facts(Self.facts)])
        let store = GitFactsStore(fetch: { _ in await answers.next() })
        let container = ContainerID.project(UUID())
        let folder = URL(fileURLWithPath: "/a")
        await store.refresh(container, at: folder)
        // The clock would wait now; the person's move does not.
        #expect(await store.read(container, at: folder) == .facts(Self.facts))
        #expect(store.facts(for: container) == Self.facts)
    }

    @Test func readingsOfAll_askedForWhileOneRuns_runOnceAfterIt() async {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .facts(Self.facts)
        })
        let target = PRStatusSyncer.Target(container: .project(UUID()), workingDirectory: URL(fileURLWithPath: "/a"))
        async let first: Void = store.refresh([target], isAll: true)
        await pollUntil { log.value == ["start a"] }
        // Two more while it runs: they return at once, and one more
        // reading follows the running one, for what it already passed.
        async let second: Void = store.refresh([target], isAll: true)
        async let third: Void = store.refresh([target], isAll: true)
        _ = await (second, third)
        #expect(log.value == ["start a"])
        gate.open()
        await first
        #expect(log.value == ["start a", "end a", "start a", "end a"])
    }

    @Test func aReadingGitLeavesUnanswered_keepsTheFactsBefore_andWaitsLongerEachTime() async {
        let answers = Answers([.facts(Self.facts), .unanswered, .unanswered, .notWorkTree])
        var clock = ContinuousClock.now
        let store = GitFactsStore(fetch: { _ in await answers.next() }, now: { clock })
        let container = ContainerID.project(UUID())
        let folder = URL(fileURLWithPath: "/a")

        await store.refresh(container, at: folder)
        await store.refresh(container, at: folder)
        // Unanswered is not "no facts".
        #expect(store.facts(for: container) == Self.facts)
        // Within the wait the folder is not asked again.
        clock += .seconds(29)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 2)

        clock += .seconds(1)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 3)
        // The second in a row waits twice as long.
        clock += .seconds(59)
        await store.refresh(container, at: folder)
        #expect(await answers.taken == 3)
        clock += .seconds(1)
        await store.refresh(container, at: folder)
        // Not a work tree is an answer: the facts go.
        #expect(await answers.taken == 4)
        #expect(store.facts(for: container) == nil)
    }

    @Test func aReadingQueuedBehindOneGitLeftUnanswered_waitsToo() async {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .unanswered
        })
        let container = ContainerID.project(UUID())
        async let first: Void = store.refresh(container, at: URL(fileURLWithPath: "/first"))
        await pollUntil { log.value == ["start first"] }
        async let second: Void = store.refresh(container, at: URL(fileURLWithPath: "/second"))
        gate.open()
        _ = await (first, second)
        #expect(log.value == ["start first", "end first"])
    }

    @Test func aReadingOfAll_stopsWhenLimpidGoesToTheBack() async {
        let front = Recorded(false)
        let store = GitFactsStore(fetch: { _ in
            front.value = false
            return .facts(Self.facts)
        })
        let (session, project) = WorkspaceSessionFixture.withProject()
        store.start(session: session) { front.value }
        let known = ContainerID.project(UUID())
        await store.refresh(known, at: URL(fileURLWithPath: "/known"))
        front.value = true
        let targets = [
            PRStatusSyncer.Target(container: .project(project.id), workingDirectory: project.rootURL),
            PRStatusSyncer.Target(container: .project(UUID()), workingDirectory: URL(fileURLWithPath: "/later"))
        ]
        await store.refresh(targets, isAll: true, first: [.project(project.id)])
        // The first folder read sends Limpid to the back: the second is not
        // read, and the folder no longer listed goes.
        #expect(store.facts(for: .project(project.id)) == Self.facts)
        #expect(store.facts(for: targets[1].container) == nil)
        #expect(store.facts(for: known) == nil)
    }

    @Test func everyWindowsSession_isReadBeforeTheOthers() async {
        let order = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            order.update { $0.append(folder.lastPathComponent) }
            return .facts(Self.facts)
        })
        let targets = ["other", "front-a", "later", "front-b"].map {
            PRStatusSyncer.Target(container: .project(UUID()), workingDirectory: URL(fileURLWithPath: "/\($0)"))
        }

        await store.refresh(targets, isAll: true, first: [targets[1].container, targets[3].container])

        #expect(Set(order.value.prefix(2)) == ["front-a", "front-b"])
        #expect(Set(order.value.suffix(2)) == ["other", "later"])
    }

    @Test func aFolderIsReadOnceAtATime_andTheLaterReadingWins() async {
        let gate = Gate<Void>()
        let log = Recorded<[String]>([])
        let store = GitFactsStore(fetch: { folder in
            await gate.pass(folder.lastPathComponent, loggingTo: log)
            return .facts(GitFactsFixture.make(branch: folder.lastPathComponent, commits: nil, unpushed: nil, base: nil))
        })
        let container = ContainerID.project(UUID())
        async let first: Void = store.refresh(container, at: URL(fileURLWithPath: "/first"))
        await pollUntil { log.value == ["start first"] }
        async let second: Void = store.refresh(container, at: URL(fileURLWithPath: "/second"))
        // Given the time to start beside the first, the second does not.
        await pollUntil(timeout: .milliseconds(200)) { log.value.count > 1 }
        #expect(log.value == ["start first"])
        gate.open()
        _ = await (first, second)
        #expect(log.value == ["start first", "end first", "start second", "end second"])
        #expect(store.facts(for: container)?.branch == "second")
    }
}

extension GitFactsStoreTests {
    /// One of the other worktrees is read at most every five minutes, unless
    /// a window shows it; the rows around it are read every time.
    @Test func anOtherWorktree_isReadAtMostEveryFiveMinutes_unlessAWindowShowsIt() async {
        let reads = Recorded<[URL]>([])
        var clock = ContinuousClock.now
        let store = GitFactsStore(fetch: { folder in
            reads.update { $0.append(folder) }
            return .facts(Self.facts)
        }, now: { clock })
        let row = URL(fileURLWithPath: "/row")
        let other = URL(fileURLWithPath: "/other")
        let otherID = ContainerID.worktree(projectID: UUID(), worktreeID: UUID())
        let targets: [PRStatusSyncer.Target] = [
            .init(container: .project(UUID()), workingDirectory: row),
            .init(container: otherID, workingDirectory: other, isOccasional: true)
        ]

        await store.refresh(targets, isAll: true)
        clock += .seconds(299)
        await store.refresh(targets, isAll: true)
        #expect(reads.value == [row, other, row])
        // Not read, it is not forgotten either.
        #expect(store.facts(for: otherID) == Self.facts)

        clock += .seconds(1)
        await store.refresh(targets, isAll: true)
        #expect(reads.value == [row, other, row, row, other])

        // Shown in a window, it is read as the row it is.
        await store.refresh(targets, isAll: true, first: [otherID])
        #expect(reads.value.suffix(2) == [other, row])
    }
}

/// Gives the answers in order, counting those taken.
private actor Answers {
    private var answers: [GitFactsRead]
    private(set) var taken = 0

    init(_ answers: [GitFactsRead]) {
        self.answers = answers
    }

    func next() -> GitFactsRead {
        taken += 1
        return answers.isEmpty ? .unanswered : answers.removeFirst()
    }
}
