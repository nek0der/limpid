// DemoFixture.swift
// Limpid — the fixed session demo mode shows: a made-up invoicing product's three projects and their worktrees, for the hero screenshot.
//
// Powers `scripts/screenshot.sh`: the same session every launch means the
// README image can be made again without setting up projects, worktrees,
// and agents by hand. Persistence is short-circuited in demo mode (see
// `SessionStore.load()` / `scheduleSave`), so the in-memory snapshot is the
// whole truth for that process.
//
// The scene is duesmith, an invoicing web app nobody makes, an afternoon with
// nine agents across its TypeScript monorepo, the Rust worker that
// renders its invoice PDFs, and a dotfiles folder. The sidebar lists all
// three under their headers: duesmith's working worktrees, one ready to clean
// up, and the agents' own worktrees Git reports; pdf-worker folded, with its
// wait on the header; dotfiles' folder alone. Everything in it is made
// up: no customer, person, company, address, or repository is real, and the
// amounts are placeholders.

import CoreGraphics
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
    // Hand-made IDs anchor the fixture's structure across runs: tests
    // assert against them and the screenshot pipeline always sees the same
    // containers, tabs, and panes. Each role has its own range in the last
    // two bytes (projects 0xB0nn, worktrees 0xC0nn, tabs 0xD0nn, panes
    // 0xE0nn), built from bytes so no string has to parse. Wall-clock
    // timestamps on badges and turns are relative to now, so the encoded JSON
    // is not bit-identical across runs; the IDs are.

    fileprivate static func fixtureID(_ role: UInt8, _ index: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, role, index))
    }

    static let duesmithProjectID = fixtureID(0xB0, 1)
    static let pdfWorkerProjectID = fixtureID(0xB0, 2)
    static let dotfilesProjectID = fixtureID(0xB0, 3)

    /// duesmith's worktrees, in the order they were made, which is the
    /// sidebar's.
    static let remindersWorktreeID = fixtureID(0xC0, 1)
    static let taxRoundingWorktreeID = fixtureID(0xC0, 2)
    static let prorationWorktreeID = fixtureID(0xC0, 3)
    static let webhookWorktreeID = fixtureID(0xC0, 4)
    static let docsWorktreeID = fixtureID(0xC0, 5)
    /// pdf-worker's.
    static let pageBreaksWorktreeID = fixtureID(0xC0, 6)
    static let batchRenderWorktreeID = fixtureID(0xC0, 7)
    /// duesmith's worktree whose pull request was merged, with nothing open
    /// or uncommitted in it: ready to clean up.
    static let csvExportWorktreeID = fixtureID(0xC0, 8)
    /// Worktrees Git reports in duesmith that nobody opened in Limpid: four
    /// an agent made for itself under `.claude/worktrees/`, and one on a
    /// detached HEAD, which goes by its folder's name.
    static let agentWorktreeIDs = (9...12).map { fixtureID(0xC0, UInt8($0)) }
    static let bisectWorktreeID = fixtureID(0xC0, 13)

    /// Every tab of the fixture, each with one pane, in the order the
    /// session lists them. A tab and its pane share the slot's number.
    enum Slot: UInt8, CaseIterable {
        case prReview = 1
        case reminders
        case dev
        case git
        case taxRounding
        case proration
        case webhook
        case docs
        case pdfMain
        case pageBreaks
        case batchRender
        case dotfiles
        case scratch
        /// The selected worktree's second agent, a Codex conversation in
        /// the same worktree, so the changes panel's timeline shows two
        /// conversations' turns in one list. Last, so the earlier
        /// slots keep their ids.
        case remindersCodex

        var tabID: UUID {
            DemoFixture.fixtureID(0xD0, rawValue)
        }

        var paneID: UUID {
            DemoFixture.fixtureID(0xE0, rawValue)
        }
    }

    // MARK: - Folders

    private static let home = URL(fileURLWithPath: "/Users/demo")

    /// A folder of the demo home's `code`, where every project and worktree
    /// of the fixture is said to be. None of them exists.
    static func folder(_ name: String) -> URL {
        home.appendingPathComponent("code/\(name)")
    }

    static var duesmithRoot: URL {
        folder("duesmith")
    }

    static var pdfWorkerRoot: URL {
        folder("pdf-worker")
    }

    static var dotfilesRoot: URL {
        folder("dotfiles")
    }

    /// The worktree the window shows, whose folder the staged turns name as
    /// their root. `scripts/screenshot.sh` starts the demo shells in the same
    /// path under its isolated home, so the pane footer reads it too.
    static var selectedWorktreeRoot: URL {
        folder("duesmith-feat-overdue-reminders")
    }

    /// `selectedWorktreeRoot` below the demo home, as the script spells it.
    static var selectedWorktreeHomeRelativePath: String {
        "code/duesmith-feat-overdue-reminders"
    }

    // MARK: - Containers

    static var remindersContainer: ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: remindersWorktreeID)
    }

    static var docsContainer: ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: docsWorktreeID)
    }

    static var pageBreaksContainer: ContainerID {
        .worktree(projectID: pdfWorkerProjectID, worktreeID: pageBreaksWorktreeID)
    }

    static var batchRenderContainer: ContainerID {
        .worktree(projectID: pdfWorkerProjectID, worktreeID: batchRenderWorktreeID)
    }

    static var csvExportContainer: ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: csvExportWorktreeID)
    }

    static var prorationContainer: ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: prorationWorktreeID)
    }

    /// The third of the agents' own worktrees, `agent-a19e5b`, whose
    /// request was closed without merging.
    static var closedAgentContainer: ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: agentWorktreeIDs[2])
    }

    private static func duesmith(_ worktreeID: UUID) -> ContainerID {
        .worktree(projectID: duesmithProjectID, worktreeID: worktreeID)
    }

    // MARK: - Layout

    /// The window the hero is: 1440×900 points, the size whose 2x capture
    /// the script checks for, at (16, 16) so it also fits a 1470×956 display.
    static let windowFrame = CGRect(x: 16, y: 16, width: 1440, height: 900)
    /// Narrower than the default sidebar and changes panel, so a terminal of
    /// 100 columns at the demo's 12-point font fits beside both and the
    /// changes panel opens without folding the sidebar away.
    static let sidebarWidth: Double = 264
    static let changesPanelWidth: Double = 312

    // MARK: - Snapshot

    static var snapshot: SessionSnapshot {
        var window = WindowRecord(
            projectID: duesmithProjectID,
            activeTabID: Slot.reminders.tabID,
            activeContainerID: remindersContainer,
            frame: WindowFrame(windowFrame),
            sidebarWidth: sidebarWidth
        )
        window.isChangesPanelPresented = true
        window.changesPanelWidth = changesPanelWidth
        window.isFront = true
        window.sidebar = sidebarArrangement

        return SessionSnapshot(
            projects: projects,
            tabs: duesmithTabs() + pdfWorkerTabs() + otherTabs(),
            windows: [window],
            recentProjectPaths: [duesmithRoot, pdfWorkerRoot, dotfilesRoot],
            projectViews: [
                // Switched to, pdf-worker comes back on the agent waiting in
                // it, as a project the person had open would.
                ProjectView(
                    projectID: pdfWorkerProjectID,
                    activeContainerID: pageBreaksContainer,
                    activeTabID: Slot.pageBreaks.tabID
                ),
                ProjectView(
                    projectID: dotfilesProjectID,
                    activeContainerID: .project(dotfilesProjectID),
                    activeTabID: Slot.dotfiles.tabID
                )
            ]
        )
    }

    /// How the window lists the projects: in the order they were opened,
    /// with pdf-worker folded, so its header carries the wait inside it.
    /// duesmith and dotfiles are open, and neither folded section of
    /// duesmith is.
    static var sidebarArrangement: SidebarArrangement {
        SidebarArrangement(
            projectOrder: [duesmithProjectID, pdfWorkerProjectID, dotfilesProjectID],
            collapsedProjects: [pdfWorkerProjectID]
        )
    }

    /// The worktrees are `.userPinned` so `GitSyncCoordinator` leaves them
    /// alone: their folders do not exist, and a scan would drop them. Each
    /// project names its main folder's branch, which its first row reads.
    private static var projects: [Project] {
        [
            Project(
                id: duesmithProjectID,
                name: "duesmith",
                rootURL: duesmithRoot,
                worktrees: [
                    worktree(remindersWorktreeID, "feat/overdue-reminders", "duesmith-feat-overdue-reminders"),
                    worktree(taxRoundingWorktreeID, "fix/tax-rounding", "duesmith-fix-tax-rounding"),
                    worktree(prorationWorktreeID, "feat/proration", "duesmith-feat-proration"),
                    worktree(webhookWorktreeID, "fix/webhook-timeout", "duesmith-fix-webhook-timeout"),
                    worktree(docsWorktreeID, "docs/invoices-api", "duesmith-docs-invoices-api"),
                    worktree(csvExportWorktreeID, "fix/csv-export", "duesmith-fix-csv-export")
                ] + agentWorktrees + [bisectWorktree],
                paletteIndex: 12, // sky
                mainBranchName: "main"
            ),
            Project(
                id: pdfWorkerProjectID,
                name: "pdf-worker",
                rootURL: pdfWorkerRoot,
                worktrees: [
                    worktree(pageBreaksWorktreeID, "fix/page-breaks", "pdf-worker-fix-page-breaks"),
                    worktree(batchRenderWorktreeID, "feat/batch-render", "pdf-worker-feat-batch-render")
                ],
                paletteIndex: 5, // moss
                mainBranchName: "main"
            ),
            Project(
                id: dotfilesProjectID,
                name: "dotfiles",
                rootURL: dotfilesRoot,
                paletteIndex: 4, // lavender
                mainBranchName: "main"
            )
        ]
    }

    /// A worktree Limpid made, which is among the working rows unless its
    /// pull request says it is done.
    private static func worktree(_ id: UUID, _ branch: String, _ folderName: String) -> Worktree {
        Worktree(
            id: id,
            label: branch,
            workingDirectory: folder(folderName),
            gitRef: GitRef(branchName: branch),
            origin: .userPinned,
            admission: .created
        )
    }

    /// The agents' own worktrees in duesmith, which Git reports and nobody
    /// opened: folded among the other worktrees.
    private static var agentWorktrees: [Worktree] {
        zip(agentWorktreeIDs, ["agent-3f2a91", "agent-7c0d44", "agent-a19e5b", "agent-e62b07"]).map { id, name in
            Worktree(
                id: id,
                label: name,
                workingDirectory: duesmithRoot.appendingPathComponent(".claude/worktrees/\(name)"),
                gitRef: GitRef(branchName: "worktree-\(name)"),
                origin: .userPinned,
                admission: .discovered
            )
        }
    }

    /// A checkout on a detached HEAD beside duesmith, left from a bisect.
    private static var bisectWorktree: Worktree {
        Worktree(
            id: bisectWorktreeID,
            label: "duesmith-bisect",
            workingDirectory: folder("duesmith-bisect"),
            gitRef: GitRef(branchName: nil, headSHA: "4be1c09"),
            origin: .userPinned,
            admission: .discovered
        )
    }

    // MARK: - Worktrees

    //
    // Rows are named as a real session's usually are, by their branch, not
    // by a label the person gave: no worktree has one
    // (`Worktree.displayName`) and no tab has one (`titleOverride`). A label
    // would put the row's branch at the head of its second line
    // (`WorkspaceSession.rowCheckout(of:)`), and the hero has no room for
    // it. Each agent's tab comes first in its worktree, and its terminal's
    // title is its first conversation's (`Tab.conversationName`), which the
    // pane strip reads; a worktree of shells alone has no conversation.
    // Badge times sit 20 seconds past a whole minute, so the rows' minutes
    // do not tick over in the seconds before the capture.

    private static func duesmithTabs() -> [Tab] {
        let review = agentTab(
            .prReview,
            .codex,
            in: .project(duesmithProjectID),
            badge: badge(
                .finished,
                secondsAgo: prReviewFinishedSecondsAgo,
                prompt: prReviewLastPrompt,
                root: duesmithRoot
            )
        )

        let reminders = agentTab(
            .reminders,
            .claude,
            in: remindersContainer,
            badge: badge(
                .finished,
                // This is when its last staged turn ended (`DemoFixture.conversations`).
                secondsAgo: remindersFinishedSecondsAgo,
                prompt: remindersLastPrompt,
                root: selectedWorktreeRoot
            )
        )

        let migration = agentTab(
            .remindersCodex,
            .codex,
            in: remindersContainer,
            badge: badge(
                .finished,
                secondsAgo: remindersCodexFinishedSecondsAgo,
                prompt: remindersCodexLastPrompt,
                sessionStartedSecondsAgo: remindersCodexSessionStartedSecondsAgo,
                root: selectedWorktreeRoot
            )
        )

        // A permission request at Codex's own prompt, which demo mode leaves
        // to the agent (it runs no approval service). Codex's hook records
        // only the tool's name; the demo stages the "Tool: argument" words
        // Claude's hook records instead, so the row has a command to show.
        // The record says it is an approval of that tool, as a wait's
        // record does.
        var tax = agentTab(
            .taxRounding,
            .codex,
            in: duesmith(taxRoundingWorktreeID),
            badge: badge(
                .needsInput,
                detail: "Bash: tsc",
                secondsAgo: 200,
                prompt: "Round tax per line item, not on the invoice total",
                runningFor: 330,
                root: folder("duesmith-fix-tax-rounding")
            )
        )
        tax.agentBadges[.codex]?[Slot.taxRounding.paneID]?.waitKind = PromptWaitKind.approval.rawValue
        tax.agentBadges[.codex]?[Slot.taxRounding.paneID]?.tool = "Bash"

        let proration = agentTab(
            .proration,
            .claude,
            in: duesmith(prorationWorktreeID),
            badge: badge(
                .running,
                detail: "Bash: pnpm test src/billing",
                secondsAgo: 80,
                prompt: "Charge the difference when a customer upgrades mid-cycle",
                runningFor: 260,
                root: folder("duesmith-feat-proration")
            )
        )

        let webhook = agentTab(
            .webhook,
            .claude,
            in: duesmith(webhookWorktreeID),
            badge: badge(
                .error,
                detail: "API Error: Request timed out.",
                secondsAgo: webhookStoppedSecondsAgo,
                prompt: webhookLastPrompt,
                root: folder("duesmith-fix-webhook-timeout")
            )
        )

        let docs = agentTab(
            .docs,
            .codex,
            in: docsContainer,
            badge: badge(
                .idle,
                secondsAgo: 1940,
                prompt: "Document the invoices API and open a pull request",
                root: folder("duesmith-docs-invoices-api")
            )
        )

        return [
            review,
            reminders,
            migration,
            shellTab(.dev, in: remindersContainer, title: "dev"),
            shellTab(.git, in: remindersContainer, title: "git"),
            tax,
            proration,
            webhook,
            docs
        ]
    }

    private static func pdfWorkerTabs() -> [Tab] {
        var pageBreaks = agentTab(
            .pageBreaks,
            .codex,
            in: pageBreaksContainer,
            badge: badge(
                .needsInput,
                detail: "Bash: cargo test -p layout",
                secondsAgo: 380,
                prompt: "Keep line items from splitting across page breaks",
                runningFor: 520,
                root: folder("pdf-worker-fix-page-breaks")
            )
        )
        pageBreaks.agentBadges[.codex]?[Slot.pageBreaks.paneID]?.waitKind = PromptWaitKind.approval.rawValue
        pageBreaks.agentBadges[.codex]?[Slot.pageBreaks.paneID]?.tool = "Bash"

        let batchRender = agentTab(
            .batchRender,
            .claude,
            in: batchRenderContainer,
            badge: badge(
                .idle,
                secondsAgo: 10820,
                prompt: "Render invoices in batches of 50",
                root: folder("pdf-worker-feat-batch-render")
            )
        )

        return [
            shellTab(.pdfMain, in: .project(pdfWorkerProjectID)),
            pageBreaks,
            batchRender
        ]
    }

    private static func otherTabs() -> [Tab] {
        [
            shellTab(.dotfiles, in: .project(dotfilesProjectID)),
            shellTab(.scratch, in: .loose)
        ]
    }

    // MARK: - Pull-request status

    /// Pull-request state the demo hands to `PRStatusStore`, standing
    /// in for what the forge CLIs would report.
    ///
    /// The hero screenshot has to look the same on every
    /// contributor's Mac, and the live path cannot promise that — it
    /// shells out to `gh` / `glab` against whatever is on disk under
    /// whatever credentials happen to be present. In demo mode `AppState`
    /// hands this to `PRStatusSyncer` as its source
    /// (`PRStatusSource.fixture`) instead.
    ///
    /// One open request with passing checks; a draft whose checks are
    /// still running, on the worktree whose agent is running, so its row
    /// keeps the running action as its second line and carries the mark on
    /// the right; one closed without merging, on an agent's own worktree
    /// folded among the other worktrees, so no top row shows it; one merged
    /// in the other project, with a tab still open in it; and one merged in
    /// duesmith, whose worktree has nothing open, which puts it among those
    /// ready to clean up. No failing checks:
    /// their red mark reads too much like a stop beside the scene's real one.
    ///
    /// The demo's worktrees are `.userPinned` to stop
    /// `GitSyncCoordinator` replacing them with a scan of paths that
    /// do not exist. That flag is a fixture mechanism, not a claim
    /// about the row, so it carries an ordinary worktree's status.
    static var prStatus: [ContainerID: PRInfo] {
        [
            docsContainer: PRInfo(
                number: 324,
                state: .open,
                isDraft: false,
                title: "docs(api): document the invoices endpoints",
                url: demoPullRequestURL(repo: "duesmith", number: 324),
                forge: .gitHub,
                checks: PRChecks(conclusion: .success, counts: .init(passed: 3, total: 3))
            ),
            prorationContainer: PRInfo(
                number: 326,
                state: .open,
                isDraft: true,
                title: "feat(billing): prorate plan changes mid-cycle",
                url: demoPullRequestURL(repo: "duesmith", number: 326),
                forge: .gitHub,
                checks: PRChecks(conclusion: .pending, counts: .init(passed: 2, total: 4))
            ),
            closedAgentContainer: PRInfo(
                number: 317,
                state: .closed,
                isDraft: false,
                title: "refactor(billing): split the invoice totals module",
                url: demoPullRequestURL(repo: "duesmith", number: 317),
                forge: .gitHub,
                checks: PRChecks(conclusion: .success, counts: .init(passed: 3, total: 3))
            ),
            csvExportContainer: PRInfo(
                number: 311,
                state: .merged,
                isDraft: false,
                title: "fix(export): quote commas in the CSV export",
                url: demoPullRequestURL(repo: "duesmith", number: 311),
                forge: .gitHub,
                checks: PRChecks(conclusion: .success, counts: .init(passed: 3, total: 3))
            ),
            batchRenderContainer: PRInfo(
                number: 57,
                state: .merged,
                isDraft: false,
                title: "feat(render): render invoices in batches",
                url: demoPullRequestURL(repo: "pdf-worker", number: 57),
                forge: .gitHub,
                checks: PRChecks(conclusion: .success, counts: .init(passed: 4, total: 4))
            )
        ]
    }

    /// Where a demo request's "Open on GitHub" would go.
    ///
    /// `example.invalid` is reserved by RFC 2606 and never resolves,
    /// which is the point: a plausible `github.com/<something>` is a
    /// real address belonging to whoever registered that name, and the
    /// demo would hand a stranger's page to anyone who clicked.
    /// `SparkleUpdater`'s mock appcast picks it for the same reason.
    ///
    /// The fallback is unreachable: the string is assembled here from
    /// a fixed host, a repo name we choose, and an `Int`. It exists
    /// because `URL(string:)` is failable and nothing in this app
    /// force-unwraps. `DemoFixtureTests` asserts the host on every
    /// entry, so an edit that reached the fallback fails there instead
    /// of shipping a link into the demo.
    private static func demoPullRequestURL(repo: String, number: Int) -> URL {
        URL(string: "https://example.invalid/demo/\(repo)/pull/\(number)")
            ?? URL(fileURLWithPath: "/")
    }

    // MARK: - Helpers

    /// Returns what each agent's first conversation is called, as its
    /// provider titled it, which names the agent's tab. It is
    /// `nil` for a shell's slot.
    static func conversationTitle(of slot: Slot) -> String? {
        switch slot {
        case .prReview: "Review PR #318"
        case .reminders: "Send overdue invoice reminders"
        case .remindersCodex: "Migrate the reminder schedules"
        case .taxRounding: "Fix tax rounding on line items"
        case .proration: "Add proration to plan changes"
        case .webhook: "Retry webhooks on timeout"
        case .docs: "Document the invoices API"
        case .pageBreaks: "Fix page breaks in long invoices"
        case .batchRender: "Render invoices in batches"
        case .dev, .git, .pdfMain, .dotfiles, .scratch: nil
        }
    }

    /// Makes an agent's tab, with `badge` on its one pane and named by the
    /// conversation in it, staged as a pass leaves a tab once the provider
    /// has titled the conversation: the tab keeps the conversation's name
    /// (`Tab.conversationName`), and its title is that
    /// name too, as the agent last set it. Demo mode runs no pass, so the
    /// name stays as staged; a scene that holds the screen sets the same
    /// title again once its shell starts (`transcript(for:)`), in place of
    /// the folder the shell reports first. A slot missing from
    /// `conversationTitle(of:)` falls back to the provider's name, which
    /// `DemoFixtureTests` catches.
    private static func agentTab(_ slot: Slot, _ agent: AgentKind, in container: ContainerID, badge staged: AgentBadge) -> Tab {
        let name = conversationTitle(of: slot) ?? agent.rawValue
        let badge = titled(staged, slot: slot, agent: agent)
        var tab = Tab(
            id: slot.tabID,
            title: name,
            splitTree: SplitTree(leafID: slot.paneID),
            container: container
        )
        tab.agentBadges[agent, default: [:]][slot.paneID] = badge
        tab.conversationName = ConversationName(
            name: name,
            provider: agent,
            paneID: slot.paneID,
            conversationID: badge.conversationID,
            startedAt: badge.sessionStartedAt
        )
        tab.initialCommands[slot.paneID] = transcript(for: slot)
        return tab
    }

    /// `badge` as a run that has reported its conversation holds it, for a
    /// slot whose conversation the fixture stages turns for
    /// (`conversation(forPane:)`): the conversation's ID and its title
    /// where the provider keeps it, Claude's generated title and Codex's
    /// thread name. The tab's name, the pane header, the turns' recorded
    /// title, and the changes panel then call the conversation the same.
    private static func titled(_ badge: AgentBadge, slot: Slot, agent: AgentKind) -> AgentBadge {
        guard let conversation = conversation(forPane: slot.paneID) else { return badge }
        var badge = badge
        badge.conversationID = conversation.conversationID
        switch agent {
        case .claude: badge.providerGeneratedTitle = conversationTitle(of: slot)
        case .codex: badge.providerSessionTitle = conversationTitle(of: slot)
        }
        return badge
    }

    /// A shell tab with no name of its own, so its row reads as its branch.
    /// `title` is what its terminal last reported, which the pane strip
    /// shows until the shell starts and reports its own: only the selected
    /// tab's pane starts in the hero.
    private static func shellTab(_ slot: Slot, in container: ContainerID, title: String = "shell") -> Tab {
        var tab = Tab(
            id: slot.tabID,
            title: title,
            splitTree: SplitTree(leafID: slot.paneID),
            container: container
        )
        tab.initialCommands[slot.paneID] = transcript(for: slot)
        return tab
    }

    /// A badge as the hook would leave it, its times relative to now so the
    /// rows read as fresh on every launch. Its session began an hour before
    /// it last reported, unless `sessionStartedSecondsAgo` says when.
    private static func badge(
        _ state: AgentState,
        detail: String? = nil,
        secondsAgo: Int,
        prompt: String,
        runningFor: Int? = nil,
        sessionStartedSecondsAgo: Int? = nil,
        root: URL
    ) -> AgentBadge {
        AgentBadge(
            state: state,
            detail: detail,
            runStartedAt: runningFor.map { Date(timeIntervalSinceNow: -TimeInterval($0)) },
            updatedAt: Date(timeIntervalSinceNow: -TimeInterval(secondsAgo)),
            lastPrompt: prompt,
            worktreeRoot: root.path,
            sessionStartedAt: Date(timeIntervalSinceNow: -TimeInterval(sessionStartedSecondsAgo ?? secondsAgo + 3600))
        )
    }
}
