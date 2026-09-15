// WorktreeRouting.swift
// Limpid — what the worktree hook needs to know, written where it can read it.

import Foundation
import OSLog

private let log = Logger.limpid("worktree.routing")

/// The projects a hook may route a `git worktree add` into, in the shape the
/// hook needs rather than the shape the interface keeps.
///
/// The hook read `state.json` directly until this file existed, which made
/// every change to the session schema a change the hook had to follow. This
/// file is narrow enough to be stable, versioned so a hook that cannot read it
/// passes the command through rather than guessing, and written in the same
/// operation as the session itself so the two cannot drift.
struct WorktreeRouting: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "worktree-routing.json"

    var schemaVersion: Int = Self.currentVersion
    var projects: [Entry] = []

    struct Entry: Codable, Equatable {
        /// Absolute path, already resolved. The hook compares it against a
        /// working directory, so it must not have to decode a URL to do it.
        var root: String
        var placement: Placement
        var bootstrap: [Step]
        /// Per provider, whether that agent's worktree creation is routed
        /// through this project's rules. A provider absent from the map is
        /// routed; only an explicit false opts out.
        var routing: [String: Bool]
    }

    struct Placement: Codable, Equatable {
        var kind: WorktreeRoutingPlacementKind
        /// Only for `custom`: the directory new worktrees are created in.
        var parent: String?
    }

    struct Step: Codable, Equatable {
        var command: String
        /// Relative to the new worktree root; absent means the root itself.
        var cwd: String?
    }
}

/// Which rule decides where a new worktree goes. The spelling is the contract:
/// the hook matches these words.
enum WorktreeRoutingPlacementKind: String, Codable {
    case siblingPrefixed
    case insideHidden
    case custom
}

extension WorktreeRouting {
    /// Derives the routing from the projects a session is about to save.
    init(projects: [Project]) {
        self.init(
            schemaVersion: Self.currentVersion,
            projects: projects.map { project in
                Entry(
                    root: project.rootURL.standardizedFileURL.path,
                    placement: Placement(project.worktreePlacement),
                    bootstrap: project.bootstrap.map {
                        Step(command: $0.cmd, cwd: $0.cwd)
                    },
                    routing: [
                        AgentKind.claude.rawValue: project.routeClaudeWorktrees,
                        AgentKind.codex.rawValue: project.routeCodexWorktrees
                    ]
                )
            }
        )
    }

    /// Writes the routing beside the session file.
    ///
    /// Best effort and logged: a failure means the hook keeps whatever it read
    /// last, which is a stale rule rather than a lost one.
    static func write(projects: [Project], beside sessionFile: URL) {
        let url = sessionFile.deletingLastPathComponent().appendingPathComponent(fileName)
        do {
            let data = try PersistenceCoders.makeEncoder().encode(WorktreeRouting(projects: projects))
            try SecureFileWrite.writeAtomic(data, to: url)
        } catch {
            log.error("routing write failed: \(String(describing: error), privacy: .public)")
        }
    }
}

extension WorktreeRouting.Placement {
    init(_ placement: WorktreePlacement) {
        switch placement {
        case .siblingPrefixed:
            self.init(kind: .siblingPrefixed, parent: nil)
        case .insideHidden:
            self.init(kind: .insideHidden, parent: nil)
        case let .custom(parent):
            self.init(kind: .custom, parent: parent.standardizedFileURL.path)
        }
    }
}
