// RepositoryRootsTests.swift
// Limpid — each session folder's Git top level, asked once and matched against the roots turns record.

import Foundation
import Testing
@testable import Limpid

@MainActor
@Suite("Repository roots")
struct RepositoryRootsTests {
    /// Git's answers, counted, and held until released when `isHeld`.
    private actor TopLevelStub {
        private(set) var asks = 0
        private var results: [Result<URL, any Error>]
        /// Holds every ask until `release`; nil when asks answer at once.
        private let held: Gate<Void>?

        init(_ results: [Result<URL, any Error>], isHeld: Bool = false) {
            self.results = results
            held = isHeld ? Gate() : nil
        }

        func topLevel(_: URL) async throws -> URL {
            asks += 1
            await held?.wait()
            return try results.removeFirst().get()
        }

        func release() {
            held?.open()
        }

        func waitUntilHeld() async {
            await held?.waitUntilRequested()
        }
    }

    private static let folder = URL(fileURLWithPath: "/repo/app")

    @Test func aFolder_isAskedOnce_andItsTopLevelMatchesTheRootsTurnsRecord() async throws {
        let git = TopLevelStub([.success(URL(fileURLWithPath: "/repo"))])
        var resolutions: [String] = []
        // The hook writes `/private/repo` where resolving says `/repo`.
        let roots = RepositoryRoots(topLevel: { try await git.topLevel($0) }, paths: WorktreePathResolver { path in
            resolutions.append(path)
            return path.replacingOccurrences(of: "/private", with: "")
        })

        #expect(roots.answer(for: Self.folder) == nil, "not asked yet")
        await roots.resolve(Self.folder)
        await roots.resolve(Self.folder)

        #expect(await git.asks == 1)
        let answer = try #require(roots.answer(for: Self.folder))
        #expect(roots.isRoot("/repo", of: answer), "a subfolder's project reads the turns of its repository")
        #expect(roots.isRoot("/private/repo", of: answer), "as Git spells it")
        #expect(resolutions == ["/repo", "/private/repo"], "the top level once, then only the recorded root Git spelled differently, once")
        #expect(!roots.isRoot("/repo/app", of: answer))
    }

    @Test func twoAsksAtOnce_askGitOnce_andBothGetTheAnswer() async {
        let git = TopLevelStub([.success(URL(fileURLWithPath: "/repo"))], isHeld: true)
        let roots = RepositoryRoots(topLevel: { try await git.topLevel($0) }, paths: WorktreePathResolver(resolveLinks: { $0 }))

        // Tasks on this actor, queued ahead of the poll's next check. An
        // `async let` comes here from the shared pool, behind that check, and
        // after a stall of the main actor in a parallel run the check found
        // the deadline passed and neither caller waiting yet.
        let first = Task { await roots.resolve(Self.folder) }
        let second = Task { await roots.resolve(Self.folder) }
        // Both waiting on the ask before Git answers.
        await pollUntil { roots.waitingCallers[Self.folder.path, default: 0] >= 2 }
        #expect(roots.waitingCallers[Self.folder.path, default: 0] == 2)
        await git.waitUntilHeld()
        await git.release()
        _ = await (first.value, second.value)

        #expect(await git.asks == 1)
        #expect(roots.answer(for: Self.folder) == .repository(path: "/repo"))
    }

    @Test func onlyGitSayingNo_isKeptAsNoRepository_andOpeningThePanelAsksAgain() async {
        let git = TopLevelStub([
            .failure(ReviewError.timedOut),
            .failure(CancellationError()),
            .failure(ReviewError.gitFailed),
            .success(URL(fileURLWithPath: "/repo"))
        ])
        let roots = RepositoryRoots(topLevel: { try await git.topLevel($0) }, paths: WorktreePathResolver(resolveLinks: { $0 }))

        await roots.resolve(Self.folder)
        #expect(roots.answer(for: Self.folder) == .unavailable, "a timeout says nothing about the folder")
        await roots.resolve(Self.folder)
        #expect(roots.answer(for: Self.folder) == .unavailable, "asked again, and again nothing")
        await roots.resolve(Self.folder)
        #expect(roots.answer(for: Self.folder) == .notRepository)
        await roots.resolve(Self.folder)
        #expect(await git.asks == 3, "kept until asked to look again")
        #expect(!roots.isRoot("/repo/app", of: .notRepository))

        // `git init` since: opening the panel looks again.
        await roots.resolve(Self.folder, isRefreshing: true)
        #expect(roots.answer(for: Self.folder) == .repository(path: "/repo"))
    }
}
