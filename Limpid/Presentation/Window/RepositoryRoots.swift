// RepositoryRoots.swift
// Limpid — the Git top level of each session folder, asked once and shared by everything that reads turns there.

import Foundation
import Observation

/// Each session folder's Git top level, the repository the hook records
/// every turn's trees under (`git rev-parse --show-toplevel`), or that the
/// folder is in no repository. Asked once per folder and kept: the rail's
/// count and the changes panel are redrawn far more often than a folder
/// moves into or out of a repository, and asking Git on each would put a
/// process on every redraw.
@MainActor
@Observable
final class RepositoryRoots {
    enum Answer: Equatable, Sendable {
        /// The top level, with links resolved (`ReviewGit.root`).
        case repository(path: String)
        case notRepository
        /// Git did not answer (a timeout, a folder gone, Git not starting):
        /// said as such, and asked again the next time anyone asks.
        case unavailable
    }

    private(set) var answers: [String: Answer] = [:]
    /// The asks in flight, which every caller for the folder waits on: one
    /// that goes away leaves the others their answer.
    @ObservationIgnored private var asking: [String: Task<Asked, Never>] = [:]
    /// How many callers wait on each ask. For tests, which read it to know
    /// two callers share one ask; nothing in the app reads it.
    @ObservationIgnored private(set) var waitingCallers: [String: Int] = [:]
    /// Resolves each root a turn recorded through its links: the hook
    /// writes Git's own spelling (`/private/tmp/...` on macOS) and resolving
    /// gives the other (`/tmp/...`). The app's one resolver
    /// (`AppState.worktreePaths`), so the restores and the review's discards
    /// meet the roots on the same spelling.
    @ObservationIgnored private let paths: WorktreePathResolver
    @ObservationIgnored private let topLevel: @Sendable (URL) async throws -> URL

    init(
        topLevel: @escaping @Sendable (URL) async throws -> URL = { try await ReviewGit.root(at: $0) },
        paths: WorktreePathResolver = WorktreePathResolver()
    ) {
        self.topLevel = topLevel
        self.paths = paths
    }

    /// For demo mode: each folder is its own top level, as the staged
    /// folders do not exist and Git is not asked. `paths` resolves nothing
    /// for the same reason.
    static func staged(paths: WorktreePathResolver = WorktreePathResolver(resolveLinks: { $0 })) -> RepositoryRoots {
        RepositoryRoots(topLevel: { $0 }, paths: paths)
    }

    /// Whether a tree's recorded root is `answer`'s repository, by name or
    /// with links resolved.
    func isRoot(_ recorded: String, of answer: Answer) -> Bool {
        guard case let .repository(path) = answer else { return false }
        return recorded == path || paths.resolved(recorded) == path
    }

    /// How many times the path spellings were let go of
    /// (`WorktreePathResolver.generation`), after which `isRoot` may answer
    /// differently: an answer kept from it is worked out again when this
    /// moves.
    var pathGeneration: Int {
        paths.generation
    }

    /// The answer for `folder`, `nil` until Git has given one.
    func answer(for folder: URL) -> Answer? {
        answers[folder.path]
    }

    /// Asks Git for `folder` unless it has answered. Only Git saying no
    /// (`ReviewError.gitFailed`, as for a folder outside any repository) is
    /// kept as "no repository"; anything else that fails is "unavailable",
    /// and the next call asks again. The ask outlives the caller: one that
    /// goes away leaves the answer for the next. `isRefreshing` asks again
    /// about a folder found in no repository: one can be made a repository
    /// while the app runs (`git init`, a worktree made again), and opening
    /// the panel is when it matters.
    func resolve(_ folder: URL, isRefreshing: Bool = false) async {
        let key = folder.path
        switch answers[key] {
        case .repository: return
        case .notRepository where !isRefreshing: return
        case .notRepository, .unavailable, nil: break
        }
        let ask = asking[key] ?? Task { [topLevel] in
            do {
                return try await Asked.topLevel(topLevel(folder).path)
            } catch ReviewError.gitFailed {
                return Asked.notRepository
            } catch {
                return Asked.noAnswer
            }
        }
        asking[key] = ask
        waitingCallers[key, default: 0] += 1
        let asked = await ask.value
        waitingCallers[key, default: 1] -= 1
        if waitingCallers[key] == 0 {
            waitingCallers[key] = nil
        }
        if asking[key] == ask {
            asking[key] = nil
        }
        switch asked {
        // Resolved here too: `ReviewGit.root` already resolves, but the
        // matching in `isRoot` must not depend on how the ask spelled it.
        case let .topLevel(path): answers[key] = .repository(path: paths.resolved(path))
        case .notRepository: answers[key] = .notRepository
        case .noAnswer: answers[key] = .unavailable
        }
    }

    /// What one ask of Git came back with.
    enum Asked: Sendable {
        case topLevel(String)
        case notRepository
        case noAnswer
    }
}
