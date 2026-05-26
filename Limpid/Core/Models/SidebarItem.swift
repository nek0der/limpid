// SidebarItem.swift
// Limpid — Sidebar data types.
//
// The sidebar has three sections, top-to-bottom:
//
//   1. "Tabs"      → Standalone tabs (no parent). Terminal.app feel.
//   2. "Groups"    → TabGroup (label only, no path). Useful for
//                    bundling SSH connections, log tailers, etc.
//   3. "Projects"  → Project (path + optional worktrees + future
//                    AI/git automation).
//
// `Tab.owner: TabOwnership` (in Tab.swift) decides which section a tab
// shows up under.

import Foundation

// MARK: - WorkingDirectoryMode

/// How a container (or the Quick Tabs scope) decides the working
/// directory for a freshly opened tab when the caller doesn't pass an
/// explicit one. Stored as a string `rawValue` so the JSON stays
/// stable across renames; `.fixed` keeps its path in a *separate*
/// field rather than an associated value so the enum itself remains a
/// trivially Codable `String` enum (no custom enum coding needed).
enum WorkingDirectoryMode: String, Codable, Equatable, CaseIterable {
    /// The user's home directory.
    case home
    /// Inherit the currently active tab's cwd; falls back to the
    /// existing nil-cwd behaviour (home-on-launch) when there's no
    /// active tab or it has no recorded cwd.
    case inheritPrevious
    /// A fixed path carried in a companion field (`cwdPath` /
    /// `quickTabCwdPath`).
    case fixed
}

// MARK: - TabGroup

//
// A simple labelled bucket for Standalone-style tabs that the user
// wants to keep together (e.g. "Servers", "Logs"). Carries no path
// and no git intelligence — it's purely an organizational label.

struct TabGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var paletteIndex: Int?
    var isExpanded: Bool
    var lastActiveTabID: UUID?
    /// Default working-directory strategy for tabs opened under this
    /// group. We default to `.inheritPrevious` rather than `.home`:
    /// before this field existed a group tab opened with no explicit
    /// cwd (nil → libghostty's home-on-launch). `.inheritPrevious`
    /// preserves that home fallback when there's no active tab, while
    /// giving the more useful "continue where I was" behaviour once a
    /// tab is in play — a strictly nicer default that doesn't surprise
    /// existing users.
    var cwdMode: WorkingDirectoryMode = .inheritPrevious
    /// Fixed directory used only when `cwdMode == .fixed`.
    var cwdPath: URL?

    init(
        id: UUID = UUID(),
        name: String,
        paletteIndex: Int? = nil,
        isExpanded: Bool = true,
        lastActiveTabID: UUID? = nil,
        cwdMode: WorkingDirectoryMode = .inheritPrevious,
        cwdPath: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.paletteIndex = paletteIndex
        self.isExpanded = isExpanded
        self.lastActiveTabID = lastActiveTabID
        self.cwdMode = cwdMode
        self.cwdPath = cwdPath
    }

    /// We hand-roll the decoder so older snapshots (no `cwdMode` /
    /// `cwdPath` keys) rehydrate with the defaults instead of throwing.
    /// Mirrors the `Worktree` CodingKeys + `AppearanceSettings`
    /// `decodeIfPresent` back-compat pattern.
    private enum CodingKeys: String, CodingKey {
        case id, name, paletteIndex, isExpanded, lastActiveTabID, cwdMode, cwdPath
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.paletteIndex = try c.decodeIfPresent(Int.self, forKey: .paletteIndex)
        self.isExpanded = try c.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        self.lastActiveTabID = try c.decodeIfPresent(UUID.self, forKey: .lastActiveTabID)
        self.cwdMode = try c.decodeIfPresent(WorkingDirectoryMode.self, forKey: .cwdMode) ?? .inheritPrevious
        self.cwdPath = try c.decodeIfPresent(URL.self, forKey: .cwdPath)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(paletteIndex, forKey: .paletteIndex)
        try c.encode(isExpanded, forKey: .isExpanded)
        try c.encodeIfPresent(lastActiveTabID, forKey: .lastActiveTabID)
        try c.encode(cwdMode, forKey: .cwdMode)
        try c.encodeIfPresent(cwdPath, forKey: .cwdPath)
    }
}

// MARK: - Project

//
// A Project anchors a chunk of work to a directory. Its `worktrees`
// array is populated by GitSyncCoordinator when `.git` is detected,
// or by the user pinning subdirs manually. Tabs in a Project may sit
// directly under the Project header (no worktree) or under one of
// the worktrees.

struct Project: Codable, Equatable, Identifiable {
    let id: UUID
    /// Display name shown in the sidebar. Defaults to the basename of
    /// `rootURL` at creation.
    var name: String
    /// The Project's "anchor" directory. Default cwd for tabs created
    /// directly under the Project (no worktree).
    var rootURL: URL
    /// Working areas inside the Project. Auto-populated from `git
    /// worktree list` when `.git` exists; user can also pin subdirs
    /// manually (`origin = .userPinned`).
    var worktrees: [Worktree]
    /// Accent color index into `LimpidColor.projectPalette`. JSON-safe.
    var paletteIndex: Int?
    /// Sidebar expand/collapse state.
    var isExpanded: Bool
    /// Tab to restore as active when the user returns to this project.
    var lastActiveTabID: UUID?
    /// Where `New Worktree…` should put the resulting folder.
    /// `.siblingPrefixed` (the OSS default) puts it at
    /// `<rootURL>/../<repo>-<branch>`; `.insideHidden` uses
    /// `<rootURL>/.worktrees/<branch>`; `.custom(parent)` uses
    /// `<parent>/<branch>`. Settable from Project Settings.
    var worktreePlacement: WorktreePlacement
    /// Current branch checked out in the project's main worktree (the
    /// one at `rootURL`). Populated by `GitSyncCoordinator` from the
    /// main checkout entry of `git worktree list`. Nil for non-git
    /// projects or while the first sync hasn't run yet. Surfaced in
    /// the L2/L3 chrome subtitle when the project container is
    /// active.
    var mainBranchName: String?

    init(
        id: UUID = UUID(),
        name: String,
        rootURL: URL,
        worktrees: [Worktree] = [],
        paletteIndex: Int? = nil,
        isExpanded: Bool = true,
        lastActiveTabID: UUID? = nil,
        worktreePlacement: WorktreePlacement = .siblingPrefixed,
        mainBranchName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.worktrees = worktrees
        self.paletteIndex = paletteIndex
        self.isExpanded = isExpanded
        self.lastActiveTabID = lastActiveTabID
        self.worktreePlacement = worktreePlacement
        self.mainBranchName = mainBranchName
    }

    /// Resolve the final on-disk URL for a worktree with the given
    /// (already sanitized) branch leaf, using this project's
    /// placement strategy.
    func resolvedWorktreeURL(branchLeaf: String) -> URL {
        let repoBasename = rootURL.lastPathComponent
        switch worktreePlacement {
        case .siblingPrefixed:
            return rootURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(repoBasename)-\(branchLeaf)")
        case .insideHidden:
            return rootURL
                .appendingPathComponent(".worktrees")
                .appendingPathComponent(branchLeaf)
        case let .custom(parent):
            return parent.appendingPathComponent(branchLeaf)
        }
    }
}

/// Strategy for picking where `git worktree add` puts the new folder.
/// Stored per-project so each repo can keep its own convention.
enum WorktreePlacement: Codable, Equatable {
    /// `<rootURL>/../<repo>-<branch>` — sibling to the main checkout,
    /// folder name prefixed with the repo basename. OSS default
    /// (GitLens, gh proposals, lazygit community).
    case siblingPrefixed
    /// `<rootURL>/.worktrees/<branch>` — hidden subdir inside the
    /// main checkout. Needs `.worktrees/` in `.gitignore` (Limpid
    /// offers to append on first use).
    case insideHidden
    /// `<parent>/<branch>` — user-chosen parent directory.
    case custom(URL)
}

// MARK: - Worktree

struct Worktree: Codable, Equatable, Identifiable {
    let id: UUID
    /// Sidebar label (branch name, subdir name, etc.).
    var label: String
    /// cwd for tabs opened under this worktree.
    var workingDirectory: URL
    /// Non-nil when this is a real git worktree (populated by
    /// GitSyncCoordinator). Always nil for `userPinned`.
    var gitRef: GitRef?
    /// How this worktree was created. Drives display + lifecycle.
    var origin: WorktreeOrigin
    /// User explicitly hid this worktree from the sidebar. Auto-detected
    /// `gitWorktree` rows reappear when the underlying git worktree
    /// changes; `userPinned` ones can stay hidden until manually
    /// re-shown via the project's "Show Hidden Worktrees" toggle.
    var isHidden: Bool = false
    /// Transient flag set by `GitSyncCoordinator` when this worktree
    /// is no longer reported by `git worktree list` (i.e. someone
    /// deleted it outside Limpid). We keep the row in the sidebar so
    /// the user doesn't lose their session associations by surprise,
    /// but render it dimmed with a warning badge. Not persisted —
    /// resets to false on launch so the next sync re-establishes
    /// reality.
    var isMissing: Bool = false

    /// Persisted properties only. `isMissing` is transient because it
    /// reflects current disk state, not user intent — we don't want a
    /// stale "missing" flag rehydrating after a restart and confusing
    /// the user before the first sync finishes.
    private enum CodingKeys: String, CodingKey {
        case id, label, workingDirectory, gitRef, origin, isHidden
    }

    init(
        id: UUID = UUID(),
        label: String,
        workingDirectory: URL,
        gitRef: GitRef? = nil,
        origin: WorktreeOrigin,
        isHidden: Bool = false,
        isMissing: Bool = false
    ) {
        self.id = id
        self.label = label
        self.workingDirectory = workingDirectory
        self.gitRef = gitRef
        self.origin = origin
        self.isHidden = isHidden
        self.isMissing = isMissing
    }
}

enum WorktreeOrigin: String, Codable, Equatable {
    /// Discovered from `git worktree list`. `gitRef` should be non-nil.
    case gitWorktree
    /// User manually pinned a subdir. `gitRef` is typically nil.
    case userPinned
}

// MARK: - GitRef

/// Snapshot of the git state for a `Worktree.gitRef`. Updated by
/// GitSyncCoordinator; nil until the first sync completes.
struct GitRef: Codable, Equatable {
    var branchName: String?
    var worktreePath: URL?
    var headSHA: String?
    var ahead: Int
    var behind: Int
    var isDirty: Bool
    var lastFetched: Date?

    init(
        branchName: String? = nil,
        worktreePath: URL? = nil,
        headSHA: String? = nil,
        ahead: Int = 0,
        behind: Int = 0,
        isDirty: Bool = false,
        lastFetched: Date? = nil
    ) {
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.headSHA = headSHA
        self.ahead = ahead
        self.behind = behind
        self.isDirty = isDirty
        self.lastFetched = lastFetched
    }
}
