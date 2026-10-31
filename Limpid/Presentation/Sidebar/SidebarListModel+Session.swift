// SidebarListModel+Session.swift
// Limpid — builds the sidebar's headers and rows for every project from the session, the attention list, and the window's arrangement.

import Foundation

extension SidebarListModel {
    /// What the list is read from besides the session: the stores every
    /// row reads, as `SessionSidebarModel` takes them.
    struct Sources {
        let queue: AttentionQueue
        let runtimes: [AgentRuntimePresentation]
        let approvals: ApprovalLedger
        let pullRequest: (ContainerID) -> PRInfo?
        let gitFacts: (ContainerID) -> GitFacts?
        /// The agents running a turn in a project, as the project dropdown counts
        /// them (`AttentionState.runningAgentCount`).
        let running: (UUID) -> Int
        let locale: Locale
    }

    /// The sidebar of `window`: every project of `session` under its
    /// header, in the window's order (`WindowSelection.sidebarArrangement`),
    /// each row in the section `sections` places it in. A folded header
    /// builds no row: it counts them and shows what waits inside.
    /// `windowShowing` names the other window that shows a project, if one
    /// does. `openedByDrag` is drawn open whatever the arrangement says: the
    /// folded projects a dragged tab rested on, open for the drag alone.
    @MainActor
    init(
        session: WorkspaceSession,
        window: WindowID,
        sections: SidebarPresentedSections,
        windowShowing: (UUID) -> WindowID?,
        sources: Sources,
        openedByDrag: Set<UUID> = []
    ) {
        let selection = session.selection(window)
        let arrangement = selection?.sidebarArrangement ?? SidebarArrangement()
        let shown = selection?.shownProjectID
        let byID = Dictionary(session.projects.map { ($0.id, $0) }) { first, _ in first }
        // The list's items by project, grouped once rather than scanned
        // for each folded header.
        let itemsByProject = Dictionary(grouping: sources.queue.items.compactMap { item in
            item.subject.projectID.map { (project: $0, item: item) }
        }, by: \.project).mapValues { $0.map(\.item) }
        // What every open header's rows read, gathered once for them all.
        let rowSources = SessionSidebarModel.Sources(
            session: session,
            index: SidebarRowIndex(session: session, queue: sources.queue),
            runtimes: sources.runtimes,
            approvals: sources.approvals,
            locale: sources.locale
        )
        let usageLimits = UsageLimits(queue: sources.queue)
        let groups = arrangement.ordered(session.projects.map(\.id)).compactMap { id -> Group? in
            guard let project = byID[id] else { return nil }
            let listed = sections.ordered(project)
            let workingCount = listed.count { $0.section == .working }
            let isCurrent = id == shown
            let isInOtherWindow = !isCurrent && windowShowing(id) != nil
            let isCollapsed = !openedByDrag.contains(id) && (arrangement.isCollapsed(
                id,
                isOpenByDefault: SidebarFoldDefault.isOpen(
                    isCurrent: isCurrent,
                    isInOtherWindow: isInOtherWindow,
                    workingCount: workingCount
                )
            ))
            let header = SidebarProjectHeader(
                id: id,
                name: project.name,
                paletteIndex: project.paletteIndex,
                isCurrent: isCurrent,
                isCollapsed: isCollapsed,
                isInOtherWindow: isInOtherWindow,
                workingCount: workingCount,
                moreCount: listed.count - workingCount,
                marks: isCollapsed ? SidebarProjectHeader.marks(
                    counts: AttentionQueue.counts(of: itemsByProject[id] ?? []),
                    running: sources.running(id)
                ) : [],
                requestKeys: isCollapsed ? Self.requestKeys(in: itemsByProject[id] ?? []) : []
            )
            guard !isCollapsed else { return Group(header: header, rows: nil) }
            let rows = SessionSidebarModel(
                project: project,
                window: window,
                sources: rowSources,
                usageLimits: usageLimits,
                pullRequest: sources.pullRequest,
                gitFacts: sources.gitFacts,
                layout: SessionSidebarModel.Layout(
                    sections: sections,
                    openSections: Set(SidebarSection.folded.filter { arrangement.isOpen($0, of: id) })
                )
            )
            return Group(header: header, rows: rows)
        }
        self.init(
            groups: groups,
            scratchRow: SessionSidebarModel.scratchRow(window: window, sources: rowSources, usageLimits: usageLimits)
        )
    }

    /// The approvals and questions waiting among a project's `items`, in
    /// the list's order.
    private static func requestKeys(in items: [AttentionItem]) -> [ApprovalKey] {
        items.compactMap { item in
            switch item.kind {
            case let .approval(fact), let .question(fact): fact.key
            case .prompt, .stop, .unread: nil
            }
        }
    }
}

extension SidebarPresentedSections {
    /// Where every row of every project belongs by what it holds now
    /// (`computed(project:session:window:queue:pullRequest:gitFacts:)`),
    /// in one value: the sidebar lists them all, and a hold keeps any of
    /// them. A project another window shows is placed as that window
    /// selects in it (`windowShowing`).
    @MainActor
    static func computed( // swiftlint:disable:this function_parameter_count
        projectsOf session: WorkspaceSession,
        window: WindowID,
        windowShowing: (UUID) -> WindowID?,
        queue: AttentionQueue,
        pullRequest: (ContainerID) -> PRInfo?,
        gitFacts: (ContainerID) -> GitFacts?
    ) -> Self {
        var sections: [ContainerID: SidebarSection] = [:]
        // Gathered once for every project, not once for each.
        let index = SidebarRowIndex(session: session, queue: queue)
        for project in session.projects {
            let placed = computed(
                project: project,
                session: session,
                window: windowShowing(project.id) ?? window,
                index: index,
                pullRequest: pullRequest,
                gitFacts: gitFacts
            )
            sections.merge(placed.sections) { first, _ in first }
        }
        return Self(sections: sections)
    }
}
