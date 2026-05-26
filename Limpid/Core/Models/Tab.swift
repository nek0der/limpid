// Tab.swift
// Limpid — a tab is one work session. Every tab belongs to exactly one
// container (Loose / Group / Project-direct / Worktree). The container
// drives where the tab appears in the L1 sidebar and which list it
// shows up in inside L2.

import Foundation

struct Tab: Codable, Equatable, Identifiable {
    let id: UUID

    /// Title reported by libghostty (OSC 0/2). Seeded from the
    /// container at creation.
    var title: String

    /// User-pinned title override. When non-nil and non-empty, replaces
    /// the auto title in the UI.
    var titleOverride: String?

    /// cwd the tab was opened in.
    var workingDirectory: String?

    /// Latest pwd reported by libghostty's PWD action.
    var pwd: String?

    /// Pane layout inside the tab.
    var splitTree: SplitTree

    /// When non-nil, the L3 pane area renders only this leaf at full size
    /// instead of `splitTree`. tmux Prefix+z equivalent. Persisted so a
    /// zoomed tab survives quit/restore. Cleared automatically when the
    /// referenced pane goes away (split, close, etc.).
    var zoomedLeafID: UUID?

    /// Per-pane persisted state (unread count). Transient bits (bell
    /// flash, last child-exit code) live on `WindowSession.paneTransients`
    /// so flipping them doesn't reassign `tabs[idx]` and trip autosave.
    var paneStates: [UUID: PaneState] = [:]

    /// On-disk paths to per-pane scrollback files written by libghostty
    /// (`ghostty_surface_write_scrollback`) at quit. Replayed into a fresh
    /// surface via `config.initial_scrollback_path` on next launch. Each
    /// entry is consumed and cleared once replayed so a later split / re-
    /// mount doesn't double-replay it.
    var scrollbackPaths: [UUID: String] = [:]

    /// Per-pane command (paneID -> shell command) injected as typed
    /// text + newline once libghostty hands us a live surface. The
    /// surface registry caches `SurfaceView` instances per paneID, so
    /// `createSurface` (and therefore the command send) only fires
    /// once per process launch — re-mounts return the existing view.
    /// Used by demo mode to stage a reproducible hero screenshot; a
    /// future "open new tab running `claude`" feature plugs into the
    /// same slot.
    var initialCommands: [UUID: String] = [:]

    /// Where this tab lives. Drives L1 selection routing and L2 list
    /// membership.
    var container: ContainerID

    /// Per-pane Claude Code session info captured by
    /// `claude-shim/limpid-hook`. Keyed by split-tree leaf UUID
    /// (= `LIMPID_PANE_ID`) so two splits running `claude`
    /// concurrently each remember their own conversation.
    /// `ClaudeSessionTracker` reconciles this map with the on-disk
    /// records at launch. Optional default = `[:]` so an existing
    /// `state.json` decodes without a snapshot version bump.
    var claudeSessions: [UUID: ClaudeSessionInfo] = [:]

    /// Per-pane Claude agent lifecycle badges. Mirrors the on-disk
    /// state records written by `limpid-hook` on every event we
    /// subscribe to (SessionStart / UserPromptSubmit / PreToolUse /
    /// Notification / PreCompact / Stop / StopFailure / SessionEnd).
    /// `ClaudeAgentStateTracker` keeps this in sync with disk via
    /// FSEvents; `TabRow` / `ContainerRow` aggregate it for L2 / L1
    /// status icons. Optional default = `[:]` for backward compat.
    var claudeAgentBadges: [UUID: ClaudeAgentBadge] = [:]

    init(
        id: UUID = UUID(),
        title: String,
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree,
        paneStates: [UUID: PaneState] = [:],
        zoomedLeafID: UUID? = nil,
        container: ContainerID,
        claudeSessions: [UUID: ClaudeSessionInfo] = [:],
        claudeAgentBadges: [UUID: ClaudeAgentBadge] = [:]
    ) {
        self.id = id
        self.title = title
        self.titleOverride = titleOverride
        self.workingDirectory = workingDirectory
        self.pwd = pwd
        self.splitTree = splitTree
        self.paneStates = paneStates
        self.zoomedLeafID = zoomedLeafID
        self.container = container
        self.claudeSessions = claudeSessions
        self.claudeAgentBadges = claudeAgentBadges
    }

    /// Custom decoding so a `state.json` written before
    /// `claudeSessions` existed (or by a build that pre-dates the
    /// pane-keyed refactor) keeps decoding instead of throwing
    /// `keyNotFound`. We only need to special-case the brand-new key
    /// — every other field has always been present.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.titleOverride = try c.decodeIfPresent(String.self, forKey: .titleOverride)
        self.workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.pwd = try c.decodeIfPresent(String.self, forKey: .pwd)
        self.splitTree = try c.decode(SplitTree.self, forKey: .splitTree)
        self.zoomedLeafID = try c.decodeIfPresent(UUID.self, forKey: .zoomedLeafID)
        self.paneStates = try c.decodeIfPresent([UUID: PaneState].self, forKey: .paneStates) ?? [:]
        self.scrollbackPaths = try c.decodeIfPresent([UUID: String].self, forKey: .scrollbackPaths) ?? [:]
        self.initialCommands = try c.decodeIfPresent([UUID: String].self, forKey: .initialCommands) ?? [:]
        self.container = try c.decode(ContainerID.self, forKey: .container)
        self.claudeSessions = try c.decodeIfPresent(
            [UUID: ClaudeSessionInfo].self,
            forKey: .claudeSessions
        ) ?? [:]
        self.claudeAgentBadges = try c.decodeIfPresent(
            [UUID: ClaudeAgentBadge].self,
            forKey: .claudeAgentBadges
        ) ?? [:]
    }

    /// Title actually rendered in the UI. Honors a manual override; falls
    /// back to whatever libghostty last reported.
    var displayTitle: String {
        if let override = titleOverride, !override.isEmpty { return override }
        return title
    }

    /// Convenience: tab containing a single empty pane.
    static func newWithSinglePane(
        title: String,
        workingDirectory: String? = nil,
        container: ContainerID
    ) -> (tab: Tab, paneID: UUID) {
        let paneID = UUID()
        let tab = Tab(
            title: title,
            workingDirectory: workingDirectory,
            splitTree: SplitTree(leafID: paneID),
            container: container
        )
        return (tab, paneID)
    }
}

// MARK: - ContainerID

/// Which container a Tab belongs to. The four cases map 1:1 to the
/// rows the user can select in L1.
///
/// - `.loose`    : the implicit "Loose Tabs" pseudo-container (top of
///                 L1). Tabs that aren't filed under a Group or Project.
/// - `.group`    : labelled bucket, no path, no git.
/// - `.project`  : a Project's "direct" tabs — sit under the Project
///                 header itself, not under any worktree (shown as the
///                 "general" leaf in L1).
/// - `.worktree` : inside a specific worktree of a Project.
enum ContainerID: Codable, Hashable {
    case loose
    case group(UUID)
    case project(UUID)
    case worktree(projectID: UUID, worktreeID: UUID)

    var projectID: UUID? {
        switch self {
        case let .project(pid): pid
        case let .worktree(pid, _): pid
        default: nil
        }
    }

    var worktreeID: UUID? {
        if case let .worktree(_, wid) = self { return wid }
        return nil
    }

    var groupID: UUID? {
        if case let .group(gid) = self { return gid }
        return nil
    }

    /// `true` when the container is anything other than `.loose`.
    var hasParent: Bool {
        if case .loose = self { return false }
        return true
    }
}

extension Tab {
    /// Mirror of `container.projectID` so consumers can stay terse.
    var projectID: UUID? {
        container.projectID
    }

    var worktreeID: UUID? {
        container.worktreeID
    }

    var groupID: UUID? {
        container.groupID
    }
}
