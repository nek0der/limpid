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
    // Hand-rolled UUIDs keep the fixture bit-identical across runs:
    // tests can assert against them, the snapshot encodes the same
    // bytes every time, and the screenshot pipeline stays
    // reproducible. **Don't change these once a hero image is
    // shipped** — the snapshot is captured into a PNG, but the
    // tests anchor on the UUIDs.

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

    private static let editorCommand = """
    clear && cat <<'EOF'
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
    clear && cat <<'EOF'
    \u{0024} git status
    On branch feat/agent-orchestration
    Your branch is up to date with 'origin/feat/agent-orchestration'.

    Changes to be committed:
      (use \"git restore --staged <file>...\" to unstage)
            modified:   Limpid/Core/Models/WindowSession+Containers.swift
            new file:   LimpidTests/WindowSessionContainersTests.swift
    EOF
    """

    private static let gitTabCommand = """
    clear && cat <<'EOF'
    \u{0024} git log --oneline --graph -5
    * 6686ad5 feat(agents): orchestration scaffolding
    * 3c195bd chore: security / perf hardening
    * 7e5c875 docs(readme): simplify
    * 98372c9 feat: baseline implementation
    * 0155870 initial empty commit
    EOF
    """

    private static let buildTabCommand = """
    clear && cat <<'EOF'
    \u{0024} xcodebuild -scheme Limpid build | xcbeautify
    > Building Limpid (Debug)
      Compile WindowSession+Containers.swift
      Compile DemoFixture.swift
      Link Limpid
    > Build Succeeded
    EOF
    """

    private static let agentTabCommand = """
    clear && cat <<'EOF'
    [Claude Code session]
    > Refactor addOrActivateProject to return a Result so callers can
      surface filesystem errors instead of silently falling back.

    Reading WindowSession+Containers.swift...
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
            label: "feat/agent-orchestration",
            workingDirectory: limpidRoot.deletingLastPathComponent()
                .appendingPathComponent("limpid-feat-agent-orchestration"),
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
                name: "dotfiles",
                rootURL: demoHome.appendingPathComponent("code/dotfiles"),
                paletteIndex: 4, // lavender
                isExpanded: false
            ),
            Project(
                id: personalSiteProjectID,
                name: "personal-site",
                rootURL: demoHome.appendingPathComponent("code/personal-site"),
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
            splitTree: SplitTree(
                root: .split(SplitData(
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

        let tabs: [Tab] = [
            singlePaneTab(
                id: looseTabID,
                title: "shell",
                container: .loose,
                paneID: looseTabPaneID
            ),
            singlePaneTab(
                id: agentsClaudeTabID,
                title: "claude",
                container: .group(agentsGroupID),
                paneID: agentsClaudePaneID
            ),
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
            sidebarWidth: Double(LimpidLayout.l1Width),
            l2Width: Double(LimpidLayout.l2Width),
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
            splitTree: SplitTree(leafID: paneID),
            container: container
        )
    }
}
