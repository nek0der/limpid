// SessionSidebarModel+Session.swift
// Limpid — builds the sidebar's rows from the session, the attention list, and the agents.

import Foundation

extension SessionSidebarModel {
    /// How the sidebar lists a project's rows: the section of each, and the
    /// folds the window has open.
    struct Layout {
        let sections: SidebarPresentedSections
        /// The project's folded sections the window has open.
        let openSections: Set<SidebarSection>
    }

    /// The sidebar for `project` as the app's state describes it, with
    /// `window`'s session marked active. `layout` is the window's
    /// (`ProjectWindowState`); without one, every row is placed as it is
    /// now and every fold is open, which is what a list of all the rows
    /// (the worktree menu, all projects) wants.
    @MainActor
    init(
        project: Project?,
        session: WorkspaceSession,
        window: WindowID,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation],
        approvals: ApprovalLedger,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?,
        locale: Locale,
        layout: Layout? = nil
    ) {
        let index = SidebarRowIndex(session: session, queue: queue)
        self.init(
            project: project,
            window: window,
            sources: Sources(session: session, index: index, runtimes: runtimes, approvals: approvals, locale: locale),
            usageLimits: UsageLimits(queue: queue),
            pullRequest: pullRequest,
            gitFacts: gitFacts,
            layout: layout ?? project.map { project in
                Layout(
                    sections: .computed(
                        project: project,
                        session: session,
                        window: window,
                        index: index,
                        pullRequest: pullRequest,
                        gitFacts: gitFacts
                    ),
                    openSections: Set(SidebarSection.allCases)
                )
            }
        )
    }

    /// The sidebar for `project` from `sources` and `usageLimits` built
    /// once for every project the list builds (`SidebarListModel`).
    /// Without a `layout`, nothing is listed.
    @MainActor
    init(
        project: Project?,
        window: WindowID,
        sources: Sources,
        usageLimits: UsageLimits,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?,
        layout: Layout?
    ) {
        let session = sources.session
        let listed = project.flatMap { project in layout.map { $0.sections.ordered(project) } } ?? []
        let isOpen = { (section: SidebarSection) in section == .working || layout?.openSections.contains(section) == true }
        let inputs: [RowInput] = project.map { project in
            // A folded section's rows are counted, not built.
            listed.filter { isOpen($0.section) }.map { entry -> RowInput in
                var input = Self.rowInput(
                    container: entry.row,
                    project: project,
                    sources: sources,
                    git: Git(pullRequest: pullRequest(entry.row), facts: gitFacts(entry.row))
                )
                input.section = entry.section
                return input
            }
        } ?? []
        let folds = project.map { project in
            SidebarSection.folded.map { section in
                Fold(projectID: project.id, section: section, count: listed.count { $0.section == section }, isOpen: isOpen(section))
            }
        } ?? []
        self.init(
            rows: inputs,
            // A window that shows nothing marks no row, the scratch row
            // included: it stands there without showing it.
            activeContainer: session.selection(window).flatMap { $0.isChoosingProject ? nil : $0.activeContainerID },
            shownPanes: Set(session.activeTab(in: window)?.splitTree.allLeafIDs() ?? []),
            usageLimits: usageLimits,
            locale: sources.locale,
            folds: folds
        )
    }

    /// The active session's row alone, as the session header shows it:
    /// one of the project's rows, or the scratch row's. `window`'s
    /// session; none for a window the session does not know.
    @MainActor
    init(
        activeIn session: WorkspaceSession,
        window: WindowID,
        queue: AttentionQueue,
        runtimes: [AgentRuntimePresentation],
        approvals: ApprovalLedger,
        pullRequest: PRInfo?,
        gitFacts: GitFacts?,
        locale: Locale
    ) {
        guard let container = session.selection(window)?.activeContainerID else {
            self.init(rows: [], activeContainer: nil, usageLimits: UsageLimits(queue: queue), locale: locale)
            return
        }
        let input = Self.rowInput(
            container: container,
            project: container.projectID.flatMap { session.project($0) },
            sources: Sources(
                session: session,
                index: SidebarRowIndex(session: session, queue: queue),
                runtimes: runtimes,
                approvals: approvals,
                locale: locale
            ),
            git: Git(pullRequest: pullRequest, facts: gitFacts)
        )
        self.init(rows: [input], activeContainer: container, usageLimits: UsageLimits(queue: queue), locale: locale)
    }

    /// What every row is read from, built once for every project a list
    /// builds.
    struct Sources {
        let session: WorkspaceSession
        let index: SidebarRowIndex
        let runtimes: [AgentRuntimePresentation]
        let approvals: ApprovalLedger
        let locale: Locale
        /// Each runtime with the pane it shows in, as the attention list
        /// places it (`AttentionState.shownPane`): the focused pane it runs
        /// in, else its first pane in a tab. Found once for the sidebar
        /// rather than once per row, where each look goes over every tab
        /// for each of the runtime's panes.
        let placed: [(runtime: AgentRuntimePresentation, pane: UUID?)]

        @MainActor
        init(
            session: WorkspaceSession,
            index: SidebarRowIndex,
            runtimes: [AgentRuntimePresentation],
            approvals: ApprovalLedger,
            locale: Locale
        ) {
            self.session = session
            self.index = index
            self.runtimes = runtimes
            self.approvals = approvals
            self.locale = locale
            placed = runtimes.map { ($0, AttentionState.shownPane(of: $0, in: session)) }
        }
    }

    /// What a row's folder holds in Git: its branch's pull request and its
    /// commits and uncommitted files.
    private struct Git {
        let pullRequest: PRInfo?
        let facts: GitFacts?
    }

    @MainActor
    private static func rowInput(
        container: ContainerID,
        // `nil` for the scratch row, which belongs to no project.
        project: Project?,
        sources: Sources,
        git: Git
    ) -> RowInput {
        let pullRequest = git.pullRequest
        let session = sources.session
        let approvals = sources.approvals
        let tabs = sources.index.tabs(in: container)
        let panes = Set(tabs.flatMap { $0.splitTree.allLeafIDs() })
        // A runtime counts where it shows (`Sources.placed`).
        let rowPlaced = sources.placed.filter { $0.pane.map(panes.contains) ?? false }
        let rowRuntimes = rowPlaced.map(\.runtime)
        let rowAgents = rowRuntimes.map(SessionRowFact.Agent.init(runtime:))
        // An agent in front of a pane with no run placed yet (Codex before
        // its first prompt) is the row's as it is the tab's: one not
        // matched to its hook, which the row says as it does for a run
        // whose state is unknown.
        let agentsInFront = tabs.flatMap { tab in
            tab.splitTree.allLeafIDs().compactMap { pane in
                tab.agentInFrontWithoutRecord(inPane: pane).map {
                    SessionRowFact.Agent(provider: $0, state: .unknown, detail: nil)
                }
            }
        }
        // A new session that stopped before its agent started has no pane;
        // its stop is the row's by the row's folder.
        let root = session.rootDirectory(of: container)
        let items = sources.index.items(inPanes: panes, root: root)
        var requestText: [ApprovalKey: String] = [:]
        var commandRequests: Set<ApprovalKey> = []
        for item in items {
            switch item.kind {
            case let .approval(fact):
                if let request = approvals.entries[fact.key]?.presentation {
                    let text = ApprovalRequestText(request)
                    requestText[fact.key] = text.approvalText
                    if text.isCommand {
                        commandRequests.insert(fact.key)
                    }
                }
            case let .question(fact):
                if let request = approvals.entries[fact.key]?.presentation {
                    requestText[fact.key] = ApprovalRequestText(request).questionText
                }
            case .prompt, .stop, .unread:
                break
            }
        }
        // Read once: the name, the checkout beside a label, and the label
        // all follow from it.
        let rowName = session.rowName(of: container)
        let name = name(rowName, locale: sources.locale)
        return RowInput(
            container: container,
            name: name.text,
            nameTruncation: name.truncation,
            fact: SessionRowFact.Input(
                items: items,
                requestText: requestText,
                agents: rowAgents + agentsInFront,
                pullRequest: pullRequest.map {
                    SessionRowFact.PullRequest(number: $0.number, state: $0.state, isDraft: $0.isDraft)
                },
                uncommittedFiles: git.facts?.uncommittedFiles ?? 0,
                proposedCommits: git.facts?.proposedCommits ?? 0,
                hasGitFacts: git.facts != nil
            ),
            lastActivity: rowRuntimes.map(\.badge.updatedAt).max(),
            isMissing: project.flatMap { project in
                container.worktreeID.flatMap { session.worktree(projectID: project.id, worktreeID: $0) }
            }?.isMissing ?? false,
            // In `AgentKind`'s order, as the row's badges are.
            agents: AgentKind.allCases.flatMap { kind in
                agentsInFront.filter { $0.provider == kind }.map { SessionRowFact.Input(agents: [$0]) }
                    + rowRuntimes.filter { $0.kind == kind }.map { runtime in
                        SessionRowFact.Input(
                            items: items.filter { item in
                                if case let .runtime(id, _, _, _, _) = item.subject {
                                    id == runtime.id
                                } else {
                                    false
                                }
                            },
                            requestText: requestText,
                            agents: [SessionRowFact.Agent(runtime: runtime)]
                        )
                    }
            },
            isInTmux: rowRuntimes.contains { !$0.tmuxLocations.isEmpty },
            pullRequestChecks: pullRequest.flatMap { info in info.checks.map { ($0, info.forge) } },
            leadPaneID: PanePriority.dominant(items)?.subject.paneID
                ?? SessionRowFact.leadAgentIndex(of: rowAgents)
                .flatMap { rowPlaced[$0].pane }
                ?? tabs.first?.splitTree.effectiveFocusedLeafID,
            hasTabs: !tabs.isEmpty,
            branch: project == nil ? nil : CheckoutName.of(container, in: session),
            checkout: rowName.flatMap { session.rowCheckout(of: container, named: $0) },
            label: rowName?.label,
            commandRequests: commandRequests
        )
    }

    /// The name a worktree's row shows, which the Needs Attention
    /// list and the approval card name the row's items by too, so one
    /// row goes by one name wherever it is listed.
    @MainActor
    static func rowName(of container: ContainerID, in session: WorkspaceSession, locale: Locale) -> String {
        name(session.rowName(of: container), locale: locale).text
    }

    /// The row's name by the one rule (`WorkspaceSession.rowName(of:)`),
    /// and where it is cut. Tabs outside any project are "Scratch", whatever
    /// they are named, as the sidebar's scratch row says.
    private static func name(_ name: RowName?, locale: Locale) -> (text: String, truncation: SupervisionTruncation) {
        guard let name else {
            return (LocalizedStringResource("Scratch").resolved(in: locale), .name)
        }
        // A branch shares its prefix with its neighbors and differs at its
        // end, so it is cut in the middle wherever it names the row; any
        // other name, a folder's included, at its end.
        return (name.text, name.source == .branch ? .branch : .name)
    }
}
