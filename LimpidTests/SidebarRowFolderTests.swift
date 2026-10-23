// SidebarRowFolderTests.swift
// Limpid — a row the person named shows its folder: on its second line, in its tooltip, to VoiceOver, and wherever it is a choice.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct SidebarRowFolderTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// This holds a project "limpid" with one worktree in the folder
    /// "login-redesign" on the branch "feat/login", and that worktree's row.
    private struct Fixture {
        let session: WorkspaceSession
        let project: Project
        let worktree: ContainerID
    }

    private static func project() -> Fixture {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let index = session.projects.firstIndex { $0.id == project.id } ?? 0
        let worktree = Worktree(
            label: "login-redesign",
            workingDirectory: URL(fileURLWithPath: "/tmp/login-redesign"),
            gitRef: GitRef(branchName: "feat/login"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [worktree]
        return Fixture(
            session: session,
            project: session.projects[index],
            worktree: .worktree(projectID: project.id, worktreeID: worktree.id)
        )
    }

    private static func model(_ session: WorkspaceSession, _ project: Project, locale: Locale = english) -> SessionSidebarModel {
        SessionSidebarModel(
            project: project,
            session: session,
            window: session.primaryWindowID,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            pullRequest: { _ in nil },
            gitFacts: { _ in nil },
            locale: locale
        )
    }

    /// Makes a worktree's row named `name`, showing `folder` (whose full
    /// name is `fullFolder`, when it was shortened), with `fact`.
    private static func row(
        name: String = "Login work",
        folder: String?,
        fullFolder: String? = nil,
        fact: SessionRowFact.Input = .init(),
        container: ContainerID = .worktree(projectID: UUID(), worktreeID: UUID()),
        locale: Locale = english
    ) -> SessionSidebarModel.Row {
        var input = SessionSidebarModel.RowInput.test(container: container, name: name, fact: fact)
        input.folder = folder.map { RowFolder(name: fullFolder ?? $0, shown: $0) }
        input.branch = "feat/login"
        return .test(input, locale: locale)
    }

    /// Returns the whole second line as it reads: the lead, then the fact it
    /// shows.
    private static func lineTwo(_ row: SessionSidebarModel.Row, locale: Locale = english) -> String {
        let fact = SessionRowFactText.current(row, now: .now, locale: locale)
        return SessionRowFactText.lineLead(row, fact: fact, locale: locale) + (row.showsFact ? fact : "")
    }

    private static let idleAgent = SessionRowFact.Input(agents: [.init(provider: .claude, state: .idle, detail: nil)])

    // MARK: - The rule

    @Test func onlyANameThePersonGave_showsItsFolder_unlessItIsTheFolder() {
        #expect(RowName(text: "Login work", source: .manual).folderBeside("login-redesign")
            == RowFolder(name: "login-redesign", shown: "login-redesign"))
        #expect(RowName(text: "Login-Redesign", source: .manual).folderBeside("login-redesign") == nil)
        #expect(RowName(text: "Add tests", source: .conversation).folderBeside("login-redesign") == nil)
        #expect(RowName(text: "feat/login", source: .branch).folderBeside("login-redesign") == nil)
        #expect(RowName(text: "login-redesign", source: .folder).folderBeside("login-redesign") == nil)
    }

    /// A worktree Limpid made beside the project starts with the project's
    /// folder name and a hyphen. That start is the same on every worktree of
    /// the project, so the row shows only the rest.
    @Test func theProjectsPrefix_isLeftOff_theFolderShown() {
        #expect(RowFolder.shortened("duesmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding")
        #expect(RowFolder.shortened("DueSmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding", "without case")
        #expect(RowFolder.shortened("pdf-worker-fix-page-breaks", repository: "duesmith") == "pdf-worker-fix-page-breaks")
        #expect(RowFolder.shortened("duesmithy-fix", repository: "duesmith") == "duesmithy-fix", "a longer word is not the prefix")
        #expect(RowFolder.shortened("duesmith", repository: "duesmith") == "duesmith", "the project's own name is kept")
        #expect(RowFolder.shortened("duesmith-", repository: "duesmith") == "duesmith-", "nothing would be left")
        #expect(RowFolder.shortened("fix-tax-rounding", repository: nil) == "fix-tax-rounding")

        let name = RowName(text: "Tax rounding", source: .manual)
        #expect(name.folderBeside("duesmith-fix-tax-rounding", repository: "duesmith")
            == RowFolder(name: "duesmith-fix-tax-rounding", shown: "fix-tax-rounding"))
        // A name that is the shortened folder would only say it again.
        #expect(RowName(text: "Fix-Tax-Rounding", source: .manual).folderBeside("duesmith-fix-tax-rounding", repository: "duesmith")
            == nil)
    }

    /// The session shortens a worktree's folder by its project's folder
    /// name, and keeps the folder row's own folder whole.
    @Test func theSession_shortensAWorktreesFolder_byItsProjectsFolder() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let repository = project.rootURL.lastPathComponent
        #expect(repository == "duesmith")
        let worktree = Worktree(
            label: "tax",
            workingDirectory: project.rootURL.deletingLastPathComponent().appendingPathComponent("\(repository)-fix-tax-rounding"),
            gitRef: GitRef(branchName: "fix/tax-rounding"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [worktree]
        let row = ContainerID.worktree(projectID: project.id, worktreeID: worktree.id)
        session.renameRow(row, to: "Tax rounding")
        #expect(session.rowFolder(of: row) == RowFolder(name: "\(repository)-fix-tax-rounding", shown: "fix-tax-rounding"))
        session.renameRow(row, to: "fix-tax-rounding")
        #expect(session.rowFolder(of: row) == nil, "a name that is the shortened folder")

        // The project's folder row shows its folder whole, unless it is the
        // project's name, which the header says.
        let root = ContainerID.project(project.id)
        session.renameRow(root, to: "Main checkout")
        session.projects[index].name = "Duesmith App"
        #expect(session.rowFolder(of: root) == RowFolder(name: "duesmith", shown: "duesmith"))
        session.projects[index].name = "DUESMITH"
        #expect(session.rowFolder(of: root) == nil)
    }

    /// The session gives the folder for a row named on the row itself or
    /// by its first tab, the project's own folder for its folder row, and
    /// none for a row it names by its branch or the scratch row.
    @Test func theSession_givesTheFolder_ofEveryNamedRow() {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        #expect(session.rowFolder(of: worktree) == nil, "a row named by its branch")
        #expect(session.rowFolder(of: .loose) == nil)

        session.renameRow(worktree, to: "Login work")
        #expect(session.rowFolder(of: worktree)?.shown == "login-redesign")
        session.renameRow(worktree, to: "LOGIN-REDESIGN")
        #expect(session.rowFolder(of: worktree) == nil, "a name that is the folder's")
        session.renameRow(worktree, to: "")

        let tab = session.openTab(container: worktree)
        session.update(tab.id) { $0.titleOverride = "Tab name" }
        #expect(session.rowFolder(of: worktree)?.shown == "login-redesign", "a name given to its first tab")

        let root = ContainerID.project(project.id)
        #expect(session.rowFolder(of: root) == nil)
        session.renameRow(root, to: "Main checkout")
        #expect(session.rowFolder(of: root)?.shown == project.rootURL.lastPathComponent)
    }

    // MARK: - The second line

    @Test func aNamedRow_startsItsSecondLineWithItsFolder_beforeAFactThatSaysMore() {
        let row = Self.row(folder: "login-redesign", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(row.showsFact)
        #expect(SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english) == "login-redesign · ")
        #expect(Self.lineTwo(row) == "login-redesign · 3 Uncommitted")

        let japanese = Self.row(
            folder: "login-redesign",
            fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3),
            locale: Self.japanese
        )
        #expect(Self.lineTwo(japanese, locale: Self.japanese) == "login-redesign · 未コミット 3")

        let pullRequest = Self.row(folder: "login-redesign", fact: .init(pullRequest: .init(number: 12, state: .open, isDraft: false)))
        #expect(Self.lineTwo(pullRequest) == "login-redesign · PR #12 · Open")

        let tool = Self.row(
            folder: "login-redesign",
            fact: .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")])
        )
        #expect(Self.lineTwo(tool) == "login-redesign · Bash: swift test")
    }

    /// "Idle" and "Running" only name what the glyph shows: a named row
    /// shows its folder alone.
    @Test func aNamedRow_dropsAFactThatOnlyRepeatsItsState() {
        let idle = Self.row(folder: "login-redesign", fact: Self.idleAgent)
        #expect(!idle.showsFact)
        #expect(Self.lineTwo(idle) == "login-redesign")

        let running = Self.row(folder: "login-redesign", fact: .init(agents: [.init(provider: .claude, state: .running, detail: nil)]))
        #expect(running.factText == "Running")
        #expect(Self.lineTwo(running) == "login-redesign")

        let shell = Self.row(folder: "login-redesign")
        #expect(Self.lineTwo(shell) == "login-redesign")

        #expect(SessionRowFact.repeatsGlyph(.approval(nil)))
        #expect(SessionRowFact.repeatsGlyph(.stopped(.error(nil))))
        #expect(SessionRowFact.repeatsGlyph(.unread(.pending)))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.approval(PromptApproval(tool: nil, action: .command, subject: nil, detail: nil)))))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.question(detail: nil))))
        #expect(SessionRowFact.repeatsGlyph(.prompt(.unclassified(detail: nil))))
        #expect(!SessionRowFact.repeatsGlyph(.prompt(.unclassified(detail: "Proceed?"))))
        #expect(!SessionRowFact.repeatsGlyph(.stopped(.usageLimit(UsageLimit(resetAt: nil, window: "five_hour")))))
        #expect(!SessionRowFact.repeatsGlyph(.stopped(.processExited)))
        #expect(!SessionRowFact.repeatsGlyph(.unread(.unchanged)))
        #expect(!SessionRowFact.repeatsGlyph(.compacting))
    }

    /// A row the person did not name keeps its line as it was, "Idle"
    /// included, so every row keeps two lines.
    @Test func anUnnamedRow_keepsItsLine() {
        let row = Self.row(name: "feat/login", folder: nil, fact: Self.idleAgent)
        #expect(row.showsFact)
        #expect(SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english).isEmpty)
        #expect(Self.lineTwo(row) == "Idle")
    }

    /// A name that is the folder's would only be said again.
    @Test func aNameThatIsTheFolder_showsNoFolder() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        session.renameRow(worktree, to: "Login-Redesign")
        let row = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(row.folder == nil)
        #expect(Self.lineTwo(row) == "Idle")
    }

    /// The project's folder row, named, shows the project's folder, which
    /// says better than "Folder" what it is.
    @Test func theNamedFolderRow_showsTheProjectsFolder_inPlaceOfFolder() throws {
        let fixture = Self.project()
        let (session, project) = (fixture.session, fixture.project)
        let root = ContainerID.project(project.id)
        let unnamed = try #require(Self.model(session, project).rows.first { $0.id == root })
        #expect(Self.lineTwo(unnamed) == "Folder")

        session.renameRow(root, to: "Main checkout")
        let named = try #require(Self.model(session, project).rows.first { $0.id == root })
        let folder = project.rootURL.lastPathComponent
        #expect(named.name == "Main checkout")
        #expect(Self.lineTwo(named) == folder)
        #expect(SessionRowFactText.spokenLabel(for: named, projectName: "limpid", now: .now, locale: Self.english)
            == "Shell, Main checkout, Folder \(folder), limpid")
    }

    /// The folder and the fact are set apart, the lead keeping the
    /// separator, so the view can cut the fact before the folder.
    @Test func theFolderLead_endsWithTheSeparator_andHoldsNoFact() {
        let row = Self.row(folder: "login-redesign", fact: .init(uncommittedFiles: 3))
        let fact = SessionRowFactText.current(row, now: .now, locale: Self.english)
        let lead = SessionRowFactText.lineLead(row, fact: fact, locale: Self.english)
        #expect(lead + fact == AgentStatusText.joined(["login-redesign", fact], locale: Self.english))
        #expect(!lead.contains(fact))
    }

    // MARK: - Tooltip and VoiceOver

    /// The line shows the folder shortened; the tooltip and VoiceOver say
    /// it whole, so nothing is lost.
    @Test func theTooltipAndVoiceOver_sayTheFolderWhole() {
        let row = Self.row(folder: "fix-tax-rounding", fullFolder: "duesmith-fix-tax-rounding", fact: .init(uncommittedFiles: 2))
        #expect(Self.lineTwo(row) == "fix-tax-rounding · 2 Uncommitted")
        #expect(SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english)
            == "Login work · duesmith-fix-tax-rounding · feat/login")
        #expect(SessionRowFactText.spokenLabel(for: row, projectName: "duesmith", now: .now, locale: Self.english)
            == "Shell, Login work, Worktree duesmith-fix-tax-rounding, duesmith, 2 Uncommitted")
    }

    @Test func theTooltip_namesTheFolder_andTheBranchWhenItDiffers() {
        #expect(SessionRowFactText.tooltip(for: Self.row(folder: "login-redesign"), now: .now, locale: Self.english)
            == "Login work · login-redesign · feat/login")
        #expect(SessionRowFactText.tooltip(for: Self.row(folder: "Feat/Login"), now: .now, locale: Self.english)
            == "Login work · Feat/Login")
    }

    @Test func voiceOver_readsTheName_theWorktree_thenTheFactOrTheState() {
        let fact = Self.row(folder: "login-redesign", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(SessionRowFactText.spokenLabel(for: fact, projectName: "limpid", now: .now, locale: Self.english)
            == "Idle, Login work, Worktree login-redesign, limpid, 3 Uncommitted, Claude")

        // The fact dropped is the state, which VoiceOver reads first.
        let idle = Self.row(folder: "login-redesign", fact: Self.idleAgent)
        #expect(SessionRowFactText.spokenLabel(for: idle, projectName: "limpid", now: .now, locale: Self.english)
            == "Idle, Login work, Worktree login-redesign, limpid, Claude")

        let japanese = Self.row(folder: "login-redesign", fact: Self.idleAgent, locale: Self.japanese)
        #expect(SessionRowFactText.spokenLabel(for: japanese, projectName: "limpid", now: .now, locale: Self.japanese)
            == "待機中、Login work、ワークツリー login-redesign、limpid、Claude")
    }

    // MARK: - Elsewhere the row is a choice

    @Test func theWorktreeMenu_givesANamedCheckoutsFolder_thenItsBranch() {
        // The detail shows the shortened folder, and no branch that only
        // repeats it.
        #expect(WorktreeDropdownText.detail(
            name: "Tax rounding",
            branch: "fix-tax-rounding",
            folder: "~/w/duesmith-fix-tax-rounding",
            shownFolder: "fix-tax-rounding",
            agentCount: 0,
            locale: Self.english
        ) == "fix-tax-rounding")
        #expect(WorktreeDropdownText.detail(
            name: "Login work",
            branch: "feat/login",
            folder: "~/w/login-redesign",
            shownFolder: "login-redesign",
            agentCount: 2,
            locale: Self.english
        ) == "login-redesign · feat/login · Agents 2")
        #expect(WorktreeDropdownText.detail(
            name: "Login work",
            branch: "login-redesign",
            folder: "~/w/login-redesign",
            shownFolder: "login-redesign",
            agentCount: 0,
            locale: Self.english
        ) == "login-redesign")
    }

    @Test func anAllProjectsCard_isPlacedByANamedRowsFolder() {
        #expect(AllProjectsText.place(project: "limpid", branch: "feat/login", folder: "login-redesign") == "limpid / login-redesign")
        #expect(AllProjectsText.place(project: "limpid", branch: "feat/login") == "limpid / feat/login")
        #expect(AllProjectsText.spokenPlace(project: "limpid", branch: "feat/login", folder: "login-redesign", locale: Self.english)
            == "limpid, login-redesign")
    }
}
