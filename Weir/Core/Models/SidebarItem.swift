// SidebarItem.swift
// Weir — the project, worktree, and working-directory types the sidebar and the session share.
//
// A tab is in a Project (in its root folder or one of its worktrees) or
// among the scratch tabs, in none: `Tab.container: ContainerID` (in
// Tab.swift) decides which.

import Foundation
import WeirDomain

// MARK: - WorkingDirectoryMode

/// How the scratch tabs, or a scratch tab, decide the working directory
/// for a freshly opened tab or pane when the caller doesn't pass an
/// explicit one. Stored as a string `rawValue` so the JSON stays
/// stable across renames; `.fixed` keeps its path in a *separate*
/// field rather than an associated value so the enum itself remains a
/// trivially Codable `String` enum (no custom enum coding needed).
enum WorkingDirectoryMode: String, Codable, Equatable, CaseIterable {
    /// The user's home directory.
    case home
    /// Inherit the currently active tab's cwd; falls back to the
    /// existing nil-cwd behavior (home-on-launch) when there's no
    /// active tab or it has no recorded cwd.
    case inheritPrevious
    /// A fixed path carried in a companion field (`cwdPath` /
    /// `quickTabCwdPath`).
    case fixed
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
    /// Accent color index into `WeirColor.projectPalette`. JSON-safe.
    var paletteIndex: Int?
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
    /// projects or while the first sync hasn't run yet. Names the main
    /// folder's checkout wherever Weir names one (`CheckoutName`).
    var mainBranchName: String?
    /// The commit the main folder has checked out, from the same entry:
    /// what still says the folder is a repository when its HEAD is
    /// detached and it has no branch to name (`CheckoutName.isRepository`).
    /// Nil for a folder that is not one, or before the first sync; absent
    /// in a `state.json` written before it was kept, which reads as nil.
    var mainHeadSHA: String?
    /// Commands run inside each new worktree right after
    /// `git worktree add` completes — both for sidebar-initiated
    /// creates and for Claude-initiated ones (the PreToolUse hook
    /// re-enters the same code path). Empty array = no bootstrap.
    /// Items are `BootstrapItem` so a future field addition (retries,
    /// per-step env, …) lands without breaking older `state.json`.
    var bootstrap: [BootstrapItem]
    /// Whether Claude's `git worktree add` invocations get routed
    /// through this project's `worktreePlacement` + `bootstrap`. When
    /// false the PreToolUse hook passes through and Claude creates the
    /// worktree at its own default path. Defaults to `true` so a fresh
    /// Weir install hits the wedge ("worktrees follow one set of
    /// rules") out of the box; users who want Claude's defaults
    /// untouched can flip this off per-project.
    var routeClaudeWorktrees: Bool
    /// Same opt-out for Codex CLI's `git worktree add`. Symmetric with
    /// `routeClaudeWorktrees` — each agent gets its own toggle so a
    /// user can route one CLI but not the other (e.g. trust Claude
    /// with the bootstrap chain while Codex still goes to its
    /// default).
    var routeCodexWorktrees: Bool
    /// The commands that count as a turn's check, as patterns whose last
    /// word may end in `*`. Nil means the defaults the hook carries
    /// (`AgentProviderRegistry.checkDefaults`); empty means no checks.
    var checkCommands: [String]?
    /// The files Git ignores that each new worktree gets a copy of from
    /// this folder, as Project Settings lists them: paths and
    /// patterns (`IgnoredFileSelection`). Nil, as in every state.json
    /// written before the list existed, copies nothing, as empty does.
    var ignoredFilesToCopy: [String]?
    /// The name the person gave the project's own folder row, which names
    /// that row before anything its tabs or its checkout say
    /// (`WorkspaceSession.rowName(of:)`). Kept apart from `name`, which
    /// names the whole project. Nil when the person gave none, as in every
    /// state.json written before rows kept their own names.
    var rootDisplayName: String?
    /// Keys a newer build wrote on the project that this one does not
    /// know, written back as they were (`WeirSettings.unknownFields` has
    /// the pattern). Empty for a project this build made.
    var unknownFields: [String: WeirJSONValue] = [:]

    /// `isExpanded`, which the sidebar's folding wrote, is named only so
    /// that a file still carrying it drops it instead of keeping it as an
    /// unknown key.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, rootURL, worktrees, paletteIndex, lastActiveTabID, worktreePlacement
        case mainBranchName, mainHeadSHA, bootstrap, routeClaudeWorktrees, routeCodexWorktrees
        case checkCommands, ignoredFilesToCopy, rootDisplayName, isExpanded
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        id: UUID = UUID(),
        name: String,
        rootURL: URL,
        worktrees: [Worktree] = [],
        paletteIndex: Int? = nil,
        lastActiveTabID: UUID? = nil,
        worktreePlacement: WorktreePlacement = .siblingPrefixed,
        mainBranchName: String? = nil,
        mainHeadSHA: String? = nil,
        bootstrap: [BootstrapItem] = [],
        routeClaudeWorktrees: Bool = true,
        routeCodexWorktrees: Bool = true,
        checkCommands: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.rootURL = rootURL
        self.worktrees = worktrees
        self.paletteIndex = paletteIndex
        self.lastActiveTabID = lastActiveTabID
        self.worktreePlacement = worktreePlacement
        self.mainBranchName = mainBranchName
        self.mainHeadSHA = mainHeadSHA
        self.bootstrap = bootstrap
        self.routeClaudeWorktrees = routeClaudeWorktrees
        self.routeCodexWorktrees = routeCodexWorktrees
        self.checkCommands = checkCommands
    }

    /// Hand-rolled decoder so a `state.json` written before `bootstrap`
    /// existed still loads cleanly. The other fields stay `decode` (not
    /// `decodeIfPresent`) because they predate this change and are
    /// always written — a missing one means the file is genuinely
    /// corrupt and we want the loader to surface that. A file that still
    /// carries the sidebar's old `isExpanded` loads too: it is named only
    /// to be passed over.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.rootURL = try c.decode(URL.self, forKey: .rootURL)
        self.worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        self.paletteIndex = try c.decodeIfPresent(Int.self, forKey: .paletteIndex)
        self.lastActiveTabID = try c.decodeIfPresent(UUID.self, forKey: .lastActiveTabID)
        // Decode worktreePlacement with a fallback so a state.json
        // written before placement existed (or with a future case we
        // don't know about) still loads. Without `decodeIfPresent`
        // here we'd be stricter than the synthesised decoder we
        // replaced, and a very old state.json would lose every
        // project on first launch with this build.
        self.worktreePlacement = try c.decodeIfPresent(
            WorktreePlacement.self, forKey: .worktreePlacement
        ) ?? .siblingPrefixed
        self.mainBranchName = try c.decodeIfPresent(String.self, forKey: .mainBranchName)
        self.mainHeadSHA = try c.decodeIfPresent(String.self, forKey: .mainHeadSHA)
        self.bootstrap = try c.decodeIfPresent([BootstrapItem].self, forKey: .bootstrap) ?? []
        // Default `true` keeps the wedge active for existing state.json
        // files that predate this field — same opinionation the
        // initializer uses.
        self.routeClaudeWorktrees = try c.decodeIfPresent(
            Bool.self, forKey: .routeClaudeWorktrees
        ) ?? true
        self.routeCodexWorktrees = try c.decodeIfPresent(
            Bool.self, forKey: .routeCodexWorktrees
        ) ?? true
        // Absent in every state.json written before checks existed, which
        // reads as the defaults.
        self.checkCommands = try c.decodeIfPresent([String].self, forKey: .checkCommands)
        self.ignoredFilesToCopy = try c.decodeIfPresent([String].self, forKey: .ignoredFilesToCopy)
        // A value of another type costs the row's name, not the project:
        // `try?` reads it as no name.
        self.rootDisplayName = try? c.decodeIfPresent(String.self, forKey: .rootDisplayName)
        self.unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    /// Writes what the synthesized encoder wrote, then the keys a newer
    /// build added. `isExpanded` is not written again.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(rootURL, forKey: .rootURL)
        try c.encode(worktrees, forKey: .worktrees)
        try c.encodeIfPresent(paletteIndex, forKey: .paletteIndex)
        try c.encodeIfPresent(lastActiveTabID, forKey: .lastActiveTabID)
        try c.encode(worktreePlacement, forKey: .worktreePlacement)
        try c.encodeIfPresent(mainBranchName, forKey: .mainBranchName)
        try c.encodeIfPresent(mainHeadSHA, forKey: .mainHeadSHA)
        try c.encode(bootstrap, forKey: .bootstrap)
        try c.encode(routeClaudeWorktrees, forKey: .routeClaudeWorktrees)
        try c.encode(routeCodexWorktrees, forKey: .routeCodexWorktrees)
        try c.encodeIfPresent(checkCommands, forKey: .checkCommands)
        try c.encodeIfPresent(ignoredFilesToCopy, forKey: .ignoredFilesToCopy)
        try c.encodeIfPresent(rootDisplayName, forKey: .rootDisplayName)
        // A known key is written from its field alone, as
        // `SessionSnapshot.encode(to:)` does at the root.
        try CodableSidecar.encodeUnknownFields(
            unknownFields.filter { !Self.knownKeyStrings.contains($0.key) },
            to: encoder
        )
    }

    /// Resolve the final on-disk URL for a worktree with the given
    /// (already sanitized) branch leaf, using this project's
    /// placement strategy. The worktree hook resolves the same path
    /// (`worktree_path` in `rust/weir-agent-hook/src/worktree.rs`); the two
    /// sides check it against `rust/fixtures/contract/shared-values.json`.
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
    /// folder name prefixed with the repo basename. A widely used
    /// multi-worktree layout.
    case siblingPrefixed
    /// `<rootURL>/.worktrees/<branch>` — hidden subdir inside the
    /// main checkout. Needs `.worktrees/` in `.gitignore` (Weir
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
    /// Tab to restore as active when the user returns to this worktree.
    /// Scoped per-worktree (not shared with the parent Project) so
    /// switching between sibling worktrees — or to the project-direct
    /// container — preserves each one's own active tab instead of
    /// resetting to the first.
    var lastActiveTabID: UUID?
    /// User explicitly hid this worktree from the sidebar. Auto-detected
    /// `gitWorktree` rows reappear when the underlying git worktree
    /// changes; `userPinned` ones can stay hidden until manually
    /// re-shown via "Show Hidden Worktrees" in the project header's menu.
    var isHidden: Bool = false
    /// When `GitSyncCoordinator` first found this worktree no longer
    /// reported by `git worktree list` (someone deleted it outside
    /// Weir); `nil` while it is there. We keep the row in the sidebar
    /// so the user doesn't lose their session associations by surprise;
    /// it is drawn dimmed and its stop lists from this time. Not
    /// persisted — resets on launch so the next sync re-establishes
    /// reality.
    var missingSince: Date?
    /// Whether Weir made it, the person opened it, or Git only reported
    /// it. Optional because a `state.json` written before admissions
    /// were kept has none, and neither does one a newer build wrote with a
    /// value this one does not know: `GitSyncCoordinator` admits such a
    /// row by its use (`WorktreeAdmissionRule`), and until then the
    /// sidebar places it by its use alone.
    var admission: WorktreeAdmission?
    /// The name the person gave the worktree's row, which names it before
    /// anything its tabs or its checkout say (`WorkspaceSession.rowName(of:)`).
    /// Kept on the worktree rather than on a tab so that a worktree with no
    /// tab can be named and closing a tab keeps the name. Nil when the
    /// person gave none, as in every state.json written before rows kept
    /// their own names.
    var displayName: String?
    /// Keys a newer build wrote on the worktree that this one does not
    /// know, written back as they were. A sync updates a row in place
    /// (`GitSyncCoordinator.mergeWorktree`), so they stay with it.
    var unknownFields: [String: WeirJSONValue] = [:]

    var isMissing: Bool {
        missingSince != nil
    }

    /// Persisted properties only. `missingSince` is transient because it
    /// reflects current disk state, not user intent — we don't want a
    /// stale "missing" flag rehydrating after a restart and confusing
    /// the user before the first sync finishes.
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, workingDirectory, gitRef, origin, lastActiveTabID, isHidden, admission, displayName
    }

    private static let knownKeyStrings: Set<String> = Set(CodingKeys.allCases.map(\.stringValue))

    init(
        id: UUID = UUID(),
        label: String,
        workingDirectory: URL,
        gitRef: GitRef? = nil,
        origin: WorktreeOrigin,
        lastActiveTabID: UUID? = nil,
        isHidden: Bool = false,
        missingSince: Date? = nil,
        admission: WorktreeAdmission? = nil,
        displayName: String? = nil
    ) {
        self.id = id
        self.label = label
        self.workingDirectory = workingDirectory
        self.gitRef = gitRef
        self.origin = origin
        self.lastActiveTabID = lastActiveTabID
        self.isHidden = isHidden
        self.missingSince = missingSince
        self.admission = admission
        self.displayName = displayName
    }

    /// Reads the keys the synthesized decoder read, as strictly: a missing
    /// `isHidden` still fails, as it always has. Only `admission` and
    /// `displayName` are lenient. An older file has neither, and a newer
    /// build may write an admission this one does not know: the row then
    /// reads as not yet admitted, or as unnamed, rather than costing the
    /// whole session.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        workingDirectory = try c.decode(URL.self, forKey: .workingDirectory)
        gitRef = try c.decodeIfPresent(GitRef.self, forKey: .gitRef)
        origin = try c.decode(WorktreeOrigin.self, forKey: .origin)
        lastActiveTabID = try c.decodeIfPresent(UUID.self, forKey: .lastActiveTabID)
        isHidden = try c.decode(Bool.self, forKey: .isHidden)
        missingSince = nil
        // `try?` reads a value of another type as no admission, as it reads
        // a string this build does not know.
        admission = (try? c.decodeIfPresent(String.self, forKey: .admission))
            .flatMap(WorktreeAdmission.init(rawValue:))
        // Absent in a file written before rows kept their own names; a value
        // of another type costs the name, not the session.
        displayName = try? c.decodeIfPresent(String.self, forKey: .displayName)
        unknownFields = try CodableSidecar.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeyStrings)
    }

    /// Writes what the synthesized encoder wrote, and `admission` and
    /// `displayName` when the row has them: a row not yet admitted is
    /// written without `admission`, so the next launch admits it again.
    /// The keys a newer build added follow.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(workingDirectory, forKey: .workingDirectory)
        try c.encodeIfPresent(gitRef, forKey: .gitRef)
        try c.encode(origin, forKey: .origin)
        try c.encodeIfPresent(lastActiveTabID, forKey: .lastActiveTabID)
        try c.encode(isHidden, forKey: .isHidden)
        try c.encodeIfPresent(admission?.rawValue, forKey: .admission)
        try c.encodeIfPresent(displayName, forKey: .displayName)
        try CodableSidecar.encodeUnknownFields(
            unknownFields.filter { !Self.knownKeyStrings.contains($0.key) },
            to: encoder
        )
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
/// GitSyncCoordinator from `git worktree list`; nil until the first sync
/// completes.
struct GitRef: Codable, Equatable {
    var branchName: String?
    var worktreePath: URL?
    var headSHA: String?
    var lastFetched: Date?

    init(
        branchName: String? = nil,
        worktreePath: URL? = nil,
        headSHA: String? = nil,
        lastFetched: Date? = nil
    ) {
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.headSHA = headSHA
        self.lastFetched = lastFetched
    }

    private enum CodingKeys: String, CodingKey {
        case branchName, worktreePath, headSHA, lastFetched
        /// Written for older builds only, which require them in
        /// `state.json`; nothing here reads them.
        case ahead, behind, isDirty
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        worktreePath = try container.decodeIfPresent(URL.self, forKey: .worktreePath)
        headSHA = try container.decodeIfPresent(String.self, forKey: .headSHA)
        lastFetched = try container.decodeIfPresent(Date.self, forKey: .lastFetched)
    }

    /// An older build decodes `ahead`, `behind`, and `isDirty` as required
    /// keys, and would fail on the whole session without them. They are
    /// written as a clean, even tree, which is what a build that showed
    /// them showed until its own sync ran.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(branchName, forKey: .branchName)
        try container.encodeIfPresent(worktreePath, forKey: .worktreePath)
        try container.encodeIfPresent(headSHA, forKey: .headSHA)
        try container.encodeIfPresent(lastFetched, forKey: .lastFetched)
        try container.encode(0, forKey: .ahead)
        try container.encode(0, forKey: .behind)
        try container.encode(false, forKey: .isDirty)
    }
}
