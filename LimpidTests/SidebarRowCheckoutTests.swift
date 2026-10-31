// SidebarRowCheckoutTests.swift
// Limpid — a labeled row shows its branch, or its folder with none, wherever it is named.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct SidebarRowCheckoutTests {
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

    /// Makes a worktree's row labeled `name`, showing `checkout` (whose
    /// full name is `fullCheckout`, when a folder was shortened), with
    /// `fact`. The checkout is the branch unless `isBranch` says it is a
    /// folder, whose row then has no branch.
    private static func row(
        name: String = "Login work",
        checkout: String?,
        fullCheckout: String? = nil,
        isBranch: Bool = true,
        fact: SessionRowFact.Input = .init(),
        container: ContainerID = .worktree(projectID: UUID(), worktreeID: UUID()),
        locale: Locale = english
    ) -> SessionSidebarModel.Row {
        var input = SessionSidebarModel.RowInput.test(container: container, name: name, fact: fact)
        input.checkout = checkout.map { RowCheckout(name: fullCheckout ?? $0, shown: $0, isBranch: isBranch) }
        input.label = checkout == nil ? nil : name
        input.branch = isBranch ? "feat/login" : nil
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

    /// A label stands for the row on its first line, so the branch goes
    /// beside it; no other name needs one.
    @Test func onlyALabel_showsTheBranch_unlessItIsTheBranch() {
        let label = RowName(text: "Login work", source: .manual)
        #expect(label.checkoutBeside(branch: "feat/login", folder: "login-redesign")
            == RowCheckout(name: "feat/login", shown: "feat/login", isBranch: true))
        #expect(RowName(text: "Feat/Login", source: .manual).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "Add tests", source: .conversation).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "feat/login", source: .branch).checkoutBeside(branch: "feat/login", folder: "login-redesign") == nil)
        #expect(RowName(text: "login-redesign", source: .folder).checkoutBeside(branch: nil, folder: "login-redesign") == nil)
    }

    /// A label on a checkout with no branch known shows its folder.
    @Test func aLabelWithNoBranch_showsTheFolder_unlessItIsTheFolder() {
        let label = RowName(text: "Login work", source: .manual)
        #expect(label.checkoutBeside(branch: nil, folder: "login-redesign")
            == RowCheckout(name: "login-redesign", shown: "login-redesign", isBranch: false))
        #expect(label.checkoutBeside(branch: "", folder: "login-redesign")?.isBranch == false, "an empty branch is none")
        #expect(RowName(text: "Login-Redesign", source: .manual).checkoutBeside(branch: nil, folder: "login-redesign") == nil)
        #expect(label.checkoutBeside(branch: nil, folder: nil) == nil)
    }

    /// A worktree Limpid made beside the project starts with the project's
    /// folder name and a hyphen. That start is the same on every worktree of
    /// the project, so the row shows only the rest.
    @Test func theProjectsPrefix_isLeftOff_theFolderShown() {
        #expect(RowCheckout.shortened("duesmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding")
        #expect(RowCheckout.shortened("DueSmith-fix-tax-rounding", repository: "duesmith") == "fix-tax-rounding", "without case")
        #expect(RowCheckout.shortened("pdf-worker-fix-page-breaks", repository: "duesmith") == "pdf-worker-fix-page-breaks")
        #expect(RowCheckout.shortened("duesmithy-fix", repository: "duesmith") == "duesmithy-fix", "a longer word is not the prefix")
        #expect(RowCheckout.shortened("duesmith", repository: "duesmith") == "duesmith", "the project's own name is kept")
        #expect(RowCheckout.shortened("duesmith-", repository: "duesmith") == "duesmith-", "nothing would be left")
        #expect(RowCheckout.shortened("fix-tax-rounding", repository: nil) == "fix-tax-rounding")

        let name = RowName(text: "Tax rounding", source: .manual)
        #expect(name.checkoutBeside(branch: nil, folder: "duesmith-fix-tax-rounding", repository: "duesmith")
            == RowCheckout(name: "duesmith-fix-tax-rounding", shown: "fix-tax-rounding", isBranch: false))
        // A label that is the shortened folder would only say it again.
        #expect(RowName(text: "Fix-Tax-Rounding", source: .manual)
            .checkoutBeside(branch: nil, folder: "duesmith-fix-tax-rounding", repository: "duesmith") == nil)
    }

    /// The session gives a labeled worktree its branch, and one with no
    /// branch its folder shortened by its project's folder name.
    @Test func theSession_givesALabeledWorktree_itsBranch_orItsShortenedFolder() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let repository = project.rootURL.lastPathComponent
        #expect(repository == "duesmith")
        let parent = project.rootURL.deletingLastPathComponent()
        let branched = Worktree(
            label: "tax",
            workingDirectory: parent.appendingPathComponent("\(repository)-fix-tax-rounding"),
            gitRef: GitRef(branchName: "fix/tax-rounding"),
            origin: .gitWorktree
        )
        let detached = Worktree(
            label: "bisect",
            workingDirectory: parent.appendingPathComponent("\(repository)-bisect"),
            gitRef: GitRef(branchName: nil, headSHA: "abc"),
            origin: .gitWorktree
        )
        session.projects[index].worktrees = [branched, detached]
        let row = ContainerID.worktree(projectID: project.id, worktreeID: branched.id)
        session.renameRow(row, to: "Tax rounding", runtimes: [])
        #expect(session.rowCheckout(of: row) == RowCheckout(name: "fix/tax-rounding", shown: "fix/tax-rounding", isBranch: true))
        session.renameRow(row, to: "FIX/tax-rounding", runtimes: [])
        #expect(session.rowCheckout(of: row) == nil, "a label that is the branch")

        let bisect = ContainerID.worktree(projectID: project.id, worktreeID: detached.id)
        session.renameRow(bisect, to: "Find the regression", runtimes: [])
        #expect(session.rowCheckout(of: bisect) == RowCheckout(name: "\(repository)-bisect", shown: "bisect", isBranch: false))
    }

    /// The project's folder row, labeled, shows its branch; with no branch
    /// known, its folder whole, unless that is the project's name, which
    /// the header says.
    @Test func theSession_givesALabeledFolderRow_itsBranch_orItsFolder() throws {
        let rootURL = WorkspaceSessionFixture.projectRootURL("parent").appendingPathComponent("duesmith")
        let (session, project) = WorkspaceSessionFixture.withProject(name: "duesmith", rootURL: rootURL)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        let root = ContainerID.project(project.id)
        session.renameRow(root, to: "Main checkout", runtimes: [])

        session.projects[index].mainBranchName = "main"
        #expect(session.rowCheckout(of: root) == RowCheckout(name: "main", shown: "main", isBranch: true))

        session.projects[index].mainBranchName = nil
        session.projects[index].name = "Duesmith App"
        #expect(session.rowCheckout(of: root) == RowCheckout(name: "duesmith", shown: "duesmith", isBranch: false))
        session.projects[index].name = "DUESMITH"
        #expect(session.rowCheckout(of: root) == nil)
    }

    /// The session gives the checkout for a row labeled on the row itself
    /// or by its first tab, and none for a row it names by its branch or
    /// the scratch row.
    @Test func theSession_givesTheCheckout_ofEveryLabeledRow() {
        let fixture = Self.project()
        let (session, worktree) = (fixture.session, fixture.worktree)
        #expect(session.rowCheckout(of: worktree) == nil, "a row named by its branch")
        #expect(session.rowCheckout(of: .loose) == nil)

        session.renameRow(worktree, to: "Login work", runtimes: [])
        #expect(session.rowCheckout(of: worktree)?.shown == "feat/login")
        session.renameRow(worktree, to: "", runtimes: [])

        let tab = session.openTab(container: worktree)
        session.update(tab.id) { $0.titleOverride = "Tab name" }
        #expect(session.rowCheckout(of: worktree)?.shown == "feat/login", "a label given to its first tab")
    }

    /// The rename field starts from the row's label, and empty on a row
    /// with none, so the branch is never what it edits.
    @Test func theRenameField_startsFromTheLabel_andEmptyWithoutOne() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        #expect(session.rowName(of: worktree)?.label == nil)
        let unlabeled = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(unlabeled.name == "feat/login")
        #expect(unlabeled.label == nil)

        session.renameRow(worktree, to: "Login work", runtimes: [])
        #expect(session.rowName(of: worktree)?.label == "Login work")
        let labeled = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(labeled.label == "Login work")

        // A conversation names no label.
        session.renameRow(worktree, to: "", runtimes: [])
        let tab = session.openTab(container: worktree)
        session.update(tab.id) {
            $0.conversationName = ConversationName(
                name: "Add tests",
                provider: .claude,
                paneID: UUID(),
                conversationID: "c",
                startedAt: nil
            )
        }
        #expect(session.rowName(of: worktree)?.label == nil)
        // Submitting the empty field it starts with renames nothing.
        #expect(InlineRenameField.submission(draft: "", startedFrom: "", submitsEmptyName: true) == nil)
    }

    /// Remove Label clears the label as an empty field does: the row goes
    /// by its branch again, with nothing beside it.
    @Test func removingTheLabel_handsTheRowBackToItsBranch() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        session.renameRow(worktree, to: "Login work", runtimes: [])
        session.renameRow(worktree, to: "", runtimes: [])
        #expect(session.rowName(of: worktree) == RowName(text: "feat/login", source: .branch))
        let row = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(row.label == nil)
        #expect(row.checkout == nil)
    }

    // MARK: - The second line

    @Test func aLabeledRow_startsItsSecondLineWithItsBranch_beforeAFactThatSaysMore() {
        let row = Self.row(checkout: "feat/login", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(row.showsFact)
        #expect(SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english) == "feat/login · ")
        #expect(Self.lineTwo(row) == "feat/login · 3 files uncommitted")

        let japanese = Self.row(
            checkout: "feat/login",
            fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3),
            locale: Self.japanese
        )
        #expect(Self.lineTwo(japanese, locale: Self.japanese) == "feat/login · 未コミット 3 ファイル")

        let pullRequest = Self.row(checkout: "feat/login", fact: .init(pullRequest: .init(number: 12, state: .open, isDraft: false)))
        #expect(Self.lineTwo(pullRequest) == "feat/login · PR #12 · Open")

        let tool = Self.row(
            checkout: "feat/login",
            fact: .init(agents: [.init(provider: .claude, state: .running, detail: "Bash: swift test")])
        )
        #expect(Self.lineTwo(tool) == "feat/login · Bash: swift test")
    }

    /// "Idle" and "Running" only name what the glyph shows: a labeled row
    /// shows its branch alone.
    @Test func aLabeledRow_dropsAFactThatOnlyRepeatsItsState() {
        let idle = Self.row(checkout: "feat/login", fact: Self.idleAgent)
        #expect(!idle.showsFact)
        #expect(Self.lineTwo(idle) == "feat/login")

        let running = Self.row(checkout: "feat/login", fact: .init(agents: [.init(provider: .claude, state: .running, detail: nil)]))
        #expect(running.factText == "Running")
        #expect(Self.lineTwo(running) == "feat/login")

        let shell = Self.row(checkout: "feat/login")
        #expect(Self.lineTwo(shell) == "feat/login")

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

    /// A row the person did not label keeps its line as it was, "Idle"
    /// included, so every row keeps two lines.
    @Test func anUnlabeledRow_keepsItsLine() {
        let row = Self.row(name: "feat/login", checkout: nil, fact: Self.idleAgent)
        #expect(row.showsFact)
        #expect(SessionRowFactText.lineLead(row, fact: row.factText, locale: Self.english).isEmpty)
        #expect(Self.lineTwo(row) == "Idle")
    }

    /// A label that is the branch would only be said again.
    @Test func aLabelThatIsTheBranch_showsNoCheckout() throws {
        let fixture = Self.project()
        let (session, project, worktree) = (fixture.session, fixture.project, fixture.worktree)
        session.renameRow(worktree, to: "Feat/Login", runtimes: [])
        let row = try #require(Self.model(session, project).rows.first { $0.id == worktree })
        #expect(row.checkout == nil)
        #expect(Self.lineTwo(row) == "Idle")
    }

    /// The project's folder row, labeled, shows the project's folder when
    /// no branch is known, in place of a fact that only names its state.
    @Test func theLabeledFolderRowWithNoBranch_showsTheProjectsFolder_inPlaceOfTheState() throws {
        let fixture = Self.project()
        let (session, project) = (fixture.session, fixture.project)
        let root = ContainerID.project(project.id)
        let unnamed = try #require(Self.model(session, project).rows.first { $0.id == root })
        #expect(Self.lineTwo(unnamed) == "Idle")

        session.renameRow(root, to: "Main checkout", runtimes: [])
        let named = try #require(Self.model(session, project).rows.first { $0.id == root })
        let folder = project.rootURL.lastPathComponent
        #expect(named.name == "Main checkout")
        #expect(Self.lineTwo(named) == folder)
        #expect(SessionRowFactText.spokenLabel(for: named, projectName: "limpid", now: .now, locale: Self.english)
            == "Shell, Main checkout, Folder \(folder), limpid, Repository folder")
    }

    /// The project's folder row, labeled, shows its branch as any labeled
    /// row does; its mark, not its line, says it is the repository.
    @Test func theLabeledFolderRowWithABranch_showsItsBranch_asAWorktreeDoes() throws {
        let fixture = Self.project()
        let (session, project) = (fixture.session, fixture.project)
        let index = try #require(session.projects.firstIndex { $0.id == project.id })
        session.projects[index].mainBranchName = "main"
        let root = ContainerID.project(project.id)
        session.renameRow(root, to: "Main checkout", runtimes: [])
        let named = try #require(Self.model(session, session.projects[index]).rows.first { $0.id == root })
        #expect(Self.lineTwo(named) == "main")
        #expect(SessionRowFactText.spokenLabel(for: named, projectName: "limpid", now: .now, locale: Self.english)
            == "Shell, Main checkout, Branch main, limpid, Repository folder")
    }

    /// The checkout and the fact are set apart, the lead keeping the
    /// separator, so the view can cut the fact before the checkout.
    @Test func theCheckoutLead_endsWithTheSeparator_andHoldsNoFact() {
        let row = Self.row(checkout: "feat/login", fact: .init(uncommittedFiles: 3))
        let fact = SessionRowFactText.current(row, now: .now, locale: Self.english)
        let lead = SessionRowFactText.lineLead(row, fact: fact, locale: Self.english)
        #expect(lead + fact == AgentStatusText.joined(["feat/login", fact], locale: Self.english))
        #expect(!lead.contains(fact))
    }

    // MARK: - Tooltip and VoiceOver

    /// The line shows a folder shortened; the tooltip and VoiceOver say it
    /// whole, so nothing is lost.
    @Test func theTooltipAndVoiceOver_sayTheFolderWhole() {
        let row = Self.row(
            checkout: "fix-tax-rounding",
            fullCheckout: "duesmith-fix-tax-rounding",
            isBranch: false,
            fact: .init(uncommittedFiles: 2)
        )
        #expect(Self.lineTwo(row) == "fix-tax-rounding · 2 files uncommitted")
        #expect(SessionRowFactText.tooltip(for: row, now: .now, locale: Self.english)
            == "Login work · duesmith-fix-tax-rounding")
        #expect(SessionRowFactText.spokenLabel(for: row, projectName: "duesmith", now: .now, locale: Self.english)
            == "Shell, Login work, Worktree duesmith-fix-tax-rounding, duesmith, 2 files uncommitted")
    }

    /// The branch beside a label is said once.
    @Test func theTooltip_namesTheBranchOnce() {
        #expect(SessionRowFactText.tooltip(for: Self.row(checkout: "feat/login"), now: .now, locale: Self.english)
            == "Login work · feat/login")
    }

    @Test func voiceOver_readsTheLabel_theBranch_thenTheFactOrTheState() {
        let fact = Self.row(checkout: "feat/login", fact: .init(agents: Self.idleAgent.agents, uncommittedFiles: 3))
        #expect(SessionRowFactText.spokenLabel(for: fact, projectName: "limpid", now: .now, locale: Self.english)
            == "Idle, Login work, Branch feat/login, limpid, 3 files uncommitted, Claude")

        // The fact dropped is the state, which VoiceOver reads first.
        let idle = Self.row(checkout: "feat/login", fact: Self.idleAgent)
        #expect(SessionRowFactText.spokenLabel(for: idle, projectName: "limpid", now: .now, locale: Self.english)
            == "Idle, Login work, Branch feat/login, limpid, Claude")

        let japanese = Self.row(checkout: "feat/login", fact: Self.idleAgent, locale: Self.japanese)
        #expect(SessionRowFactText.spokenLabel(for: japanese, projectName: "limpid", now: .now, locale: Self.japanese)
            == "待機中、Login work、ブランチ feat/login、limpid、Claude")
    }

    // MARK: - Elsewhere the row is a choice

    /// A labeled checkout with a branch passes no folder to show, so its
    /// line is its branch and its path, as any row not named by its branch;
    /// one with no branch gives its shortened folder.
    @Test func theWorktreeMenu_givesALabeledCheckoutsBranch_orItsFolder() {
        #expect(WorktreeDropdownText.detail(
            name: "Login work",
            branch: "feat/login",
            folder: "~/w/login-redesign",
            agentCount: 2,
            locale: Self.english
        ) == "feat/login · ~/w/login-redesign · Agents 2")
        #expect(WorktreeDropdownText.detail(
            name: "Tax rounding",
            branch: "",
            folder: "~/w/duesmith-fix-tax-rounding",
            shownFolder: "fix-tax-rounding",
            agentCount: 0,
            locale: Self.english
        ) == "fix-tax-rounding")
    }

    @Test func anAllProjectsCard_isPlacedByALabeledRowsBranch() {
        #expect(AllProjectsText.place(project: "limpid", branch: "feat/login", checkout: "feat/login") == "limpid / feat/login")
        #expect(AllProjectsText.place(project: "limpid", branch: nil, checkout: "login-redesign") == "limpid / login-redesign")
        #expect(AllProjectsText.spokenPlace(project: "limpid", branch: "feat/login", checkout: "feat/login", locale: Self.english)
            == "limpid, feat/login")
    }
}
