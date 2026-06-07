// DemoFixture.swift
// Limpid — fixed SessionSnapshot used when LIMPID_DEMO=1 is set in
// the environment. Powers the hero-screenshot recipe in
// `scripts/screenshot.sh`: the same JSON every launch means the
// README PNG can be regenerated without recreating groups /
// projects / worktrees by hand. Persistence is short-circuited in
// demo mode (see `SessionStore.load()` / `scheduleSave`), so the
// in-memory snapshot is the whole truth for that process.

import Foundation

enum DemoFixture {

    /// Set `LIMPID_DEMO=1` (any non-empty value works) before launching
    /// the app to bypass the on-disk session and use the fixture
    /// instead. Read once per process — toggling at runtime won't take.
    static let isDemoActive: Bool = {
        guard let value = ProcessInfo.processInfo.environment["LIMPID_DEMO"] else {
            return false
        }
        return !value.isEmpty
    }()

    // MARK: - Stable IDs

    //
    // Hand-rolled UUIDs anchor the fixture's structure across runs:
    // tests assert against them and the screenshot pipeline always
    // sees the same containers / tabs / panes. Wall-clock timestamps
    // on agent badges intentionally drift (relative to `Date()` so the
    // Waiting row reads as "2m ago" forever — see the comment near
    // the badge), so the encoded JSON is not bit-identical across
    // runs. **Don't change these UUIDs once a hero image is shipped**
    // — tests anchor on them.

    static let agentsGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    static let scratchGroupID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!

    static let limpidProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
    static let dotfilesProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
    static let personalSiteProjectID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B3")!

    static let limpidMainWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    static let limpidFeatWorktreeID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

    private static let looseTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    private static let agentsClaudeTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D2")!
    private static let agentsCodexTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D3")!
    private static let scratchNotesTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D4")!
    private static let limpidMainTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D5")!
    static let editorTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D6")!
    private static let gitTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D7")!
    private static let buildTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D8")!
    private static let agentTabID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D9")!

    private static let looseTabPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E3")!
    private static let agentsClaudePaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E4")!
    private static let agentsCodexPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E5")!
    private static let scratchNotesPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E6")!
    private static let limpidMainPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E7")!
    static let editorTopPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E1")!
    static let editorBottomPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E2")!
    private static let gitTabPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E8")!
    private static let buildTabPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000E9")!
    private static let agentTabPaneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000EA")!

    // MARK: - Stub command output

    //
    // Heredoc'd `cat` commands so each pane shows a deterministic,
    // environment-independent scene. We deliberately don't run real
    // tools like `lazygit` / `bat`, both because demo machines may
    // not have them installed and because their output drifts with
    // upstream releases. `clear &&` keeps the demo from
    // accumulating shell-init banners above the staged output.
    //
    // Each command first resets the prompt to a neutral `limpid $ `
    // (assignments with no command word modify the live shell; the
    // value is single-quoted so `$` stays literal in both zsh and
    // bash). Without this the post-`cat` live prompt renders the demo
    // machine's real `user@host` — e.g. the hero screenshot would
    // leak the maintainer's username. `PROMPT` covers zsh, `PS1`
    // covers bash; both resolve to the same neutral string.

    private static let editorCommand = """
    PROMPT='limpid $ ' PS1='limpid $ ' && clear && cat <<'EOF'
    // WindowSession+Containers.swift
    extension WindowSession {
        @discardableResult
        func addOrActivateProject(
            rootURL: URL,
            suggestedName: String? = nil
        ) -> Project {
            let normalized = rootURL.standardizedFileURL
            promoteRecent(normalized)
            if let existing = projects.first(where: {
                $0.rootURL.standardizedFileURL == normalized
            }) {
                activateProject(existing.id)
                return existing
            }
            let project = Project(
                name: suggestedName ?? normalized.lastPathComponent,
                rootURL: normalized,
                paletteIndex: projects.count % 8
            )
            projects.append(project)
            return project
        }
    }
    EOF
    """

    private static let gitStatusCommand = """
    PROMPT='limpid $ ' PS1='limpid $ ' && clear && cat <<'EOF'
    \u{0024} git status
    On branch feat/agents
    Your branch is up to date with 'origin/feat/agents'.

    Changes to be committed:
      (use \"git restore --staged <file>...\" to unstage)
            modified:   Limpid/Core/Models/WindowSession+Containers.swift
            new file:   LimpidTests/WindowSessionContainersTests.swift
    EOF
    """

    private static let gitTabCommand = """
    PROMPT='limpid $ ' PS1='limpid $ ' && clear && cat <<'EOF'
    \u{0024} git log --oneline --graph -5
    * 6686ad5 feat(agents): cross-pane waiting list and ⌘J cursor
    * 3c195bd feat(tab): name tabs from the agent conversation
    * 7e5c875 feat(toolbar): scale up header icons to Apple metrics
    * 98372c9 fix(codex): only export CODEX_HOME when shadow dir exists
    * 0155870 feat(transparency): follow Reduce Transparency live
    EOF
    """

    private static let buildTabCommand = """
    PROMPT='limpid $ ' PS1='limpid $ ' && clear && cat <<'EOF'
    \u{0024} xcodebuild -scheme Limpid build | xcbeautify
    > Building Limpid (Debug)
      Compile WindowSession+Containers.swift
      Compile DemoFixture.swift
      Link Limpid
    > Build Succeeded
    EOF
    """

    private static let agentTabCommand = """
    PROMPT='limpid $ ' PS1='limpid $ ' && clear && cat <<'EOF'
    [Claude Code session]
    > Refactor addOrActivateProject to return a Result so callers can
      surface filesystem errors instead of silently falling back.

    Read WindowSession+Containers.swift
    Edit WindowSession+Containers.swift
    Done.
    EOF
    """

    // MARK: - Snapshot

    static var snapshot: SessionSnapshot {
        let demoHome = URL(fileURLWithPath: "/Users/demo")
        let limpidRoot = demoHome.appendingPathComponent("code/limpid")

        let groups: [TabGroup] = [
            TabGroup(id: agentsGroupID, name: "Agents", paletteIndex: 0),
            TabGroup(id: scratchGroupID, name: "Scratch", paletteIndex: 2)
        ]

        let limpidMainWorktree = Worktree(
            id: limpidMainWorktreeID,
            label: "main",
            workingDirectory: limpidRoot,
            origin: .userPinned
        )
        let limpidFeatWorktree = Worktree(
            id: limpidFeatWorktreeID,
            label: "feat/agents",
            workingDirectory: limpidRoot.deletingLastPathComponent()
                .appendingPathComponent("limpid-feat-agents"),
            origin: .userPinned
        )

        let projects: [Project] = [
            Project(
                id: limpidProjectID,
                name: "limpid",
                rootURL: limpidRoot,
                worktrees: [limpidMainWorktree, limpidFeatWorktree],
                paletteIndex: 12, // sky
                isExpanded: true
            ),
            Project(
                id: dotfilesProjectID,
                name: "config",
                rootURL: demoHome.appendingPathComponent("code/config"),
                paletteIndex: 4, // lavender
                isExpanded: false
            ),
            Project(
                id: personalSiteProjectID,
                name: "marketing-site",
                rootURL: demoHome.appendingPathComponent("code/marketing-site"),
                paletteIndex: 5, // moss
                isExpanded: false
            )
        ]

        let featContainer = ContainerID.worktree(
            projectID: limpidProjectID,
            worktreeID: limpidFeatWorktreeID
        )

        // Editor tab — vertical SplitDirection means the divider runs
        // horizontally and the panes stack (editor on top, git status
        // below). 65/35 keeps the staged code dominant.
        var editorTab = Tab(
            id: editorTabID,
            title: "editor",
            // Pin the label so OSC 2 (`~`) doesn't replace "editor" when
            // the split panes activate — matches `singlePaneTab`'s
            // titleOverride trick.
            titleOverride: "editor",
            splitTree: SplitTree(
                root: .split(PaneSplit(
                    direction: .vertical,
                    ratio: 0.65,
                    first: .leaf(id: editorTopPaneID),
                    second: .leaf(id: editorBottomPaneID)
                )),
                focusedLeafID: editorTopPaneID
            ),
            container: featContainer
        )
        editorTab.initialCommands[editorTopPaneID] = editorCommand
        editorTab.initialCommands[editorBottomPaneID] = gitStatusCommand

        var gitTab = singlePaneTab(
            id: gitTabID,
            title: "git",
            container: featContainer,
            paneID: gitTabPaneID
        )
        gitTab.initialCommands[gitTabPaneID] = gitTabCommand

        var buildTab = singlePaneTab(
            id: buildTabID,
            title: "build",
            container: featContainer,
            paneID: buildTabPaneID
        )
        buildTab.initialCommands[buildTabPaneID] = buildTabCommand

        var agentTab = singlePaneTab(
            id: agentTabID,
            title: "agent",
            container: featContainer,
            paneID: agentTabPaneID
        )
        agentTab.initialCommands[agentTabPaneID] = agentTabCommand
        // Park the agent pane on a finished turn so the container column Waiting list
        // carries one entry and the tab column row shows a green checkmark —
        // the shape a real Claude `Stop` event produces. Timestamps
        // are relative to *now* (not a fixed epoch) so the Waiting row
        // reads as a fresh "2m ago" each launch instead of drifting
        // into "514d ago" as the README ages. The snapshot is no
        // longer bit-identical across runs, but the demo is captured
        // to a PNG before that matters — tests anchor on UUIDs.
        agentTab.claudeAgentBadges[agentTabPaneID] = ClaudeAgentBadge(
            state: .finished,
            detail: nil,
            runStartedAt: nil,
            contextTokens: nil,
            updatedAt: Date(timeIntervalSinceNow: -120),
            lastPrompt: "Refactor addOrActivateProject to return a Result"
                + " so callers can surface filesystem errors"
                + " instead of silently falling back.",
            sessionStartedAt: Date(timeIntervalSinceNow: -3600)
        )

        // Park the `claude` tab in the Agents group on a *running* turn
        // so the container column Agents row carries the blue bolt — a live agent
        // working off-screen, the other half of the Waiting story.
        var agentsClaudeTab = singlePaneTab(
            id: agentsClaudeTabID,
            title: "claude",
            container: .group(agentsGroupID),
            paneID: agentsClaudePaneID
        )
        agentsClaudeTab.claudeAgentBadges[agentsClaudePaneID] = ClaudeAgentBadge(
            state: .running,
            detail: "Edit",
            runStartedAt: Date(timeIntervalSinceNow: -30),
            contextTokens: nil,
            updatedAt: Date(timeIntervalSinceNow: -5),
            lastPrompt: "Audit the sidebar selection contrast in light mode.",
            sessionStartedAt: Date(timeIntervalSinceNow: -900)
        )

        let tabs: [Tab] = [
            singlePaneTab(
                id: looseTabID,
                title: "shell",
                container: .loose,
                paneID: looseTabPaneID
            ),
            agentsClaudeTab,
            singlePaneTab(
                id: agentsCodexTabID,
                title: "codex",
                container: .group(agentsGroupID),
                paneID: agentsCodexPaneID
            ),
            singlePaneTab(
                id: scratchNotesTabID,
                title: "notes",
                container: .group(scratchGroupID),
                paneID: scratchNotesPaneID
            ),
            singlePaneTab(
                id: limpidMainTabID,
                title: "main",
                container: .worktree(
                    projectID: limpidProjectID,
                    worktreeID: limpidMainWorktreeID
                ),
                paneID: limpidMainPaneID
            ),
            editorTab,
            gitTab,
            buildTab,
            agentTab
        ]

        return SessionSnapshot(
            groups: groups,
            projects: projects,
            tabs: tabs,
            activeTabID: editorTabID,
            activeContainerID: featContainer,
            sidebarWidth: Double(LimpidLayout.containerColumnWidth),
            tabColumnWidth: Double(LimpidLayout.tabColumnWidth),
            sidebarHidden: false,
            windowFrame: WindowFrame(CGRect(x: 100, y: 100, width: 1280, height: 800)),
            recentProjectPaths: [limpidRoot]
        )
    }

    // MARK: - Helpers

    private static func singlePaneTab(
        id: UUID,
        title: String,
        container: ContainerID,
        paneID: UUID
    ) -> Tab {
        Tab(
            id: id,
            title: title,
            // Demo tabs pin a `titleOverride` matching `title` so the
            // shell's OSC 2 pwd report (e.g. `~`) doesn't clobber the
            // fixture's named label once the pane is activated. Same
            // mechanism the user's manual rename uses, so `displayTitle`
            // keeps "agent" / "git" / "build" across taps.
            titleOverride: title,
            splitTree: SplitTree(leafID: paneID),
            container: container
        )
    }
}
