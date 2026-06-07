// Tab.swift
// Limpid — a tab is one work session. Every tab belongs to exactly one
// container (Loose / Group / Project-direct / Worktree). The container
// drives where the tab appears in the container column sidebar and which list it
// shows up in inside tab column.

import Foundation

struct Tab: Codable, Equatable, Identifiable {

    /// Wire-level discriminator so a future tab kind (editor, agent
    /// dashboard, …) can land without breaking an older build that opens
    /// the same `state.json`. The defensive decoder routes unknown raw
    /// values back to `.terminal`, so the offending tab still loads.
    enum Kind: String, Codable, Equatable {
        case terminal

        static let unknownFallback: Kind = .terminal

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .unknownFallback
        }
    }

    let id: UUID

    /// Wire-level kind tag. Today every tab is `.terminal`; the field
    /// exists so the next kind can be added as a Swift enum case without
    /// a state.json schema bump.
    var kind: Kind = .terminal

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

    /// When non-nil, the terminal column pane area renders only this leaf at full size
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

    /// Per-pane command (paneID → shell command) injected as typed
    /// text + newline once libghostty hands us a live surface. The
    /// surface registry caches `SurfaceView` instances per paneID, so
    /// `createSurface` (and therefore the command send) only fires
    /// once per process launch — re-mounts return the existing view.
    /// Used by demo mode to stage a reproducible hero screenshot; a
    /// future "open new tab running `claude`" feature plugs into the
    /// same slot.
    var initialCommands: [UUID: String] = [:]

    /// Where this tab lives. Drives container column selection routing and tab column list
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
    /// FSEvents; `TabRow` / `ContainerRow` aggregate it for tab column / container column
    /// status icons. Optional default = `[:]` for backward compat.
    var claudeAgentBadges: [UUID: ClaudeAgentBadge] = [:]

    /// Per-pane Codex session info captured by
    /// `codex-shim/limpid-codex-hook`. Mirror of `claudeSessions` for
    /// the Codex CLI. `CodexSessionTracker` reconciles this map with
    /// the on-disk records at launch.
    var codexSessions: [UUID: CodexSessionInfo] = [:]

    /// Per-pane Codex agent lifecycle badges. Mirror of
    /// `claudeAgentBadges` for the Codex CLI. Populated by
    /// `CodexAgentStateTracker` from on-disk state records written by
    /// `limpid-codex-hook` on every subscribed hook event.
    var codexAgentBadges: [UUID: CodexAgentBadge] = [:]

    init(
        id: UUID = UUID(),
        kind: Kind = .terminal,
        title: String,
        titleOverride: String? = nil,
        workingDirectory: String? = nil,
        pwd: String? = nil,
        splitTree: SplitTree,
        paneStates: [UUID: PaneState] = [:],
        zoomedLeafID: UUID? = nil,
        container: ContainerID,
        claudeSessions: [UUID: ClaudeSessionInfo] = [:],
        claudeAgentBadges: [UUID: ClaudeAgentBadge] = [:],
        codexSessions: [UUID: CodexSessionInfo] = [:],
        codexAgentBadges: [UUID: CodexAgentBadge] = [:]
    ) {
        self.id = id
        self.kind = kind
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
        self.codexSessions = codexSessions
        self.codexAgentBadges = codexAgentBadges
    }

    /// Custom decoding so a `state.json` written before
    /// `claudeSessions` existed (or by a build that pre-dates the
    /// pane-keyed refactor) keeps decoding instead of throwing
    /// `keyNotFound`. We only need to special-case the brand-new key
    /// — every other field has always been present.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        // Old state.json files predate the wire-level discriminator;
        // missing key defaults to `.terminal`. Unknown raw values are
        // caught by `Kind`'s defensive decoder.
        self.kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .terminal
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
        self.codexSessions = try c.decodeIfPresent(
            [UUID: CodexSessionInfo].self,
            forKey: .codexSessions
        ) ?? [:]
        self.codexAgentBadges = try c.decodeIfPresent(
            [UUID: CodexAgentBadge].self,
            forKey: .codexAgentBadges
        ) ?? [:]
    }

    /// Title actually rendered in the UI. Honors a manual override; falls
    /// back to whatever libghostty last reported.
    var displayTitle: String {
        if let override = titleOverride, !override.isEmpty { return override }
        return title
    }

    /// Pane whose Claude or Codex session started most recently — the
    /// "owner" of `title` while at least one agent is alive. Compared
    /// across both agent kinds because a tab can host a mixed set
    /// (e.g. pane 1 claude, pane 2 codex). Returns `nil` when no pane
    /// currently has a captured `sessionStartedAt`, in which case the
    /// caller falls back to whichever pane the OSC source happens to
    /// be focused on.
    ///
    /// The rule prevents an older session from clobbering a newer one:
    /// without it, pane 1 (older) typing a fresh turn would re-emit its
    /// own `firstPrompt` and overwrite pane 2's (newer) tab label.
    var latestAgentSessionPaneID: UUID? {
        var best: (paneID: UUID, started: Date)?
        for (paneID, badge) in claudeAgentBadges {
            guard let started = badge.sessionStartedAt else { continue }
            if best.map({ started > $0.started }) ?? true {
                best = (paneID, started)
            }
        }
        for (paneID, badge) in codexAgentBadges {
            guard let started = badge.sessionStartedAt else { continue }
            if best.map({ started > $0.started }) ?? true {
                best = (paneID, started)
            }
        }
        return best?.paneID
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
/// rows the user can select in container column.
///
/// - `.loose`    : the implicit "Loose Tabs" pseudo-container (top of
///                 container column). Tabs that aren't filed under a Group or Project.
/// - `.group`    : labelled bucket, no path, no git.
/// - `.project`  : a Project's "direct" tabs — sit under the Project
///                 header itself, not under any worktree (shown as the
///                 "general" leaf in container column).
/// - `.worktree` : inside a specific worktree of a Project.
///
/// Forward-compat: a future container kind (`.workspace`, …) added by
/// a newer Limpid lands in an older build's `state.json` and gets
/// folded back to `.loose` via the defensive decoder rather than
/// quarantining the whole snapshot. Same shape `Tab.Kind` /
/// `ConfirmPolicy` already follow.
enum ContainerID: Codable, Hashable {
    case loose
    case group(UUID)
    case project(UUID)
    case worktree(projectID: UUID, worktreeID: UUID)

    /// Unknown / future case lands here on decode so a state.json
    /// written by a newer Limpid still opens — the tab moves to Loose
    /// instead of dropping out of the snapshot.
    static let unknownFallback: ContainerID = .loose

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

    // MARK: - Codable

    /// Outer discriminator: the case name. Swift's auto-synthesized
    /// `Codable` for an enum with associated values writes
    /// `{ "<case>": { …assoc… } }`; we match that exact shape so the
    /// encoder side stays auto-synth and a hand-written `state.json`
    /// keeps working.
    private struct DiscriminatorKey: CodingKey, Equatable {
        var stringValue: String
        var intValue: Int? {
            nil
        }

        init?(intValue _: Int) {
            nil
        }

        init(stringValue: String) {
            self.stringValue = stringValue
        }
    }

    /// Positional payload key matching auto-synth (`{"_0": value}` for
    /// single-UUID cases). The `_0` raw name is Swift's auto-synth
    /// convention, not ours — locked here to keep the wire shape
    /// identical to what older builds wrote.
    private enum PositionalKey: String, CodingKey {
        // swiftlint:disable:next identifier_name
        case _0
    }

    /// Named payload key matching auto-synth for the worktree case.
    private enum WorktreeKey: String, CodingKey {
        case projectID
        case worktreeID
    }

    init(from decoder: any Decoder) throws {
        let outer = try decoder.container(keyedBy: DiscriminatorKey.self)
        guard let key = outer.allKeys.first else {
            self = .unknownFallback
            return
        }
        switch key.stringValue {
        case "loose":
            self = .loose
        case "group":
            let nested = try outer.nestedContainer(keyedBy: PositionalKey.self, forKey: key)
            guard let id = try? nested.decode(UUID.self, forKey: ._0) else {
                self = .unknownFallback
                return
            }
            self = .group(id)
        case "project":
            let nested = try outer.nestedContainer(keyedBy: PositionalKey.self, forKey: key)
            guard let id = try? nested.decode(UUID.self, forKey: ._0) else {
                self = .unknownFallback
                return
            }
            self = .project(id)
        case "worktree":
            let nested = try outer.nestedContainer(keyedBy: WorktreeKey.self, forKey: key)
            guard let pid = try? nested.decode(UUID.self, forKey: .projectID),
                  let wid = try? nested.decode(UUID.self, forKey: .worktreeID)
            else {
                self = .unknownFallback
                return
            }
            self = .worktree(projectID: pid, worktreeID: wid)
        default:
            // Unknown discriminator from a newer Limpid — forward-compat
            // fallback. Tab moves to Loose rather than dropping out of
            // the snapshot.
            self = .unknownFallback
        }
    }

    // `encode(to:)` stays auto-synthesized so the wire format is
    // identical to what older builds emit; no schema migration needed.
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
