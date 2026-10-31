// WorktreePathResolver.swift
// Weir — each spelling of a worktree's path with its links followed, worked out once for the whole app.

import Foundation

/// The one place a worktree path is resolved through its links. The hook
/// records Git's spelling (`/private/tmp/...` on macOS), a session folder
/// keeps the person's (`/tmp/...`), and the restore records, the review's
/// discards, and the turns' roots must all meet on one. They are worked
/// out on every draw, over every turn, and a worktree's links do not move
/// under a running app, so each spelling is resolved once and kept until
/// its project goes (`forget(_:)`).
@MainActor
final class WorktreePathResolver {
    private var resolvedPaths: [String: String] = [:]
    private let resolveLinks: (String) -> String
    /// Counts each `forget(_:)`, after which a spelling may resolve
    /// elsewhere, so an answer kept from `isRoot` is asked again.
    private(set) var generation = 0

    /// `resolveLinks` is for tests and demo mode, whose folders are not on
    /// disk.
    init(resolveLinks: @escaping (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) {
        self.resolveLinks = resolveLinks
    }

    /// `path` with its links followed.
    func resolved(_ path: String) -> String {
        if let known = resolvedPaths[path] {
            return known
        }
        let resolved = resolveLinks(path)
        resolvedPaths[path] = resolved
        return resolved
    }

    /// Whether a path names the worktree at `root`, which a snapshot or a
    /// runtime may spell through a link.
    func isRoot(_ root: String) -> (String) -> Bool {
        let target = resolved(root)
        return { [self] in $0 == root || resolved($0) == target }
    }

    /// Lets go of the spellings that resolve into `folders` (resolved
    /// paths), as their projects are removed: a folder made again later
    /// may link elsewhere.
    func forget(_ folders: [String]) {
        guard !folders.isEmpty else { return }
        generation &+= 1
        resolvedPaths = resolvedPaths.filter { _, resolved in
            !folders.contains { RepositoryPath.contains($0, resolved) }
        }
    }
}
