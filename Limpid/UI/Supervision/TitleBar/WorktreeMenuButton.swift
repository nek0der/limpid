// WorktreeMenuButton.swift
// Limpid — the title bar's worktree ▾: this project's checkouts and New Worktree….

import SwiftUI

/// Names the branch this window shows and lists the project's worktrees.
/// A separate dropdown from the project's: one changes which
/// repository, this one which checkout of it. The button says the branch,
/// which is what the title bar is there to tell (what the terminal is on),
/// and a row's name may be a conversation's that says nothing of it; the
/// list names each checkout as its sidebar row does, with the branch under
/// a name that is not it.
struct WorktreeMenuButton: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    /// The window's project, kept while a scratch tab is selected, so the
    /// control stays with the project the sidebar lists.
    private var project: Project? {
        window.selection.shownProjectID.flatMap { session.project($0) }
    }

    var body: some View {
        // A folder that is not a repository has no branch or worktrees,
        // so the control would offer nothing. A detached main checkout
        // is a repository all the same.
        if let project, CheckoutName.isRepository(project) || !project.worktrees.isEmpty {
            // On a scratch tab no checkout of the project is selected, so
            // the button names none rather than the main one.
            let isOnProject = window.selection.activeContainerID.projectID == project.id
            let branch = isOnProject
                ? CheckoutName.of(window.selection.activeContainerID, in: session) ?? CheckoutName.label(of: project)
                : nil
            TitleBarMenuButton(menu: .worktree) { isHighlighted in
                TitleBarMenuLabel(
                    title: branch ?? LocalizedStringResource("Worktrees").resolved(in: locale),
                    isHighlighted: isHighlighted,
                    textStyle: branch == nil ? .placeholder : .branch
                ) {
                    Image(systemName: ContainerSymbol.worktree)
                        .font(.supervision(LimpidLayout.Supervision.worktreeSymbolSize))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .accessibilityHidden(true)
                }
            }
            // What pressing it does; VoiceOver keeps the name of what it
            // lists, which the dropdown's heading repeats.
            .help(Text("Switch Worktree"))
            .accessibilityLabel(Text("Worktrees in \(project.name)"))
            .accessibilityValue(Text(verbatim: branch ?? ""))
        }
    }
}

/// The project's checkouts in the sidebar's order, each by the name its
/// sidebar row goes by, with its branch, its folder, and the state the row
/// shows, then New Worktree…. It
/// takes the keyboard as it opens: ↑↓ move through the checkouts from the
/// one the window shows, and Return opens the selected one, as in the
/// project dropdown (`DropdownListKeys`).
struct WorktreeDropdown: View {
    /// Closes the dropdown and hands the keyboard back to the terminal.
    let dismiss: () -> Void
    /// This is the tallest the dropdown may be under its control: the list gives
    /// up height to it, so New Worktree… stays in a short window.
    let maxHeight: CGFloat
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(PRStatusStore.self) private var prStatusStore
    @Environment(GitFactsStore.self) private var gitFacts
    @Environment(SettingsStore.self) private var settings
    @Environment(\.locale) private var locale
    @State private var selection = ListKeyboardSelection<ContainerID>(ids: [])
    /// These are the dropdown's measured height and its list's
    /// (`listHeight`): the rest is their difference, and the list gets what
    /// `maxHeight` leaves after the rest
    /// (`FloatingPanelPlacement.scrollingBodyHeight`).
    @State private var panelHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    var body: some View {
        if let projectID = window.selection.shownProjectID, let project = session.project(projectID) {
            // The sidebar's own rows, so each checkout goes by the name its
            // row has and shows the state its row does (one set of
            // glyphs), in the order the sidebar lists them.
            let sections = window.presentedSections(
                computed: .computed(
                    project: project,
                    session: session,
                    window: window.id,
                    queue: attentionQueue.queue,
                    pullRequest: { prStatusStore.info(for: $0) },
                    gitFacts: { gitFacts.facts(for: $0) }
                ),
                isDragging: false
            )
            let rows = Dictionary(
                SessionSidebarModel(
                    project: project,
                    session: session,
                    window: window.id,
                    queue: attentionQueue.queue,
                    runtimes: attention.allRuntimes,
                    approvals: approvals.ledger,
                    pullRequest: { prStatusStore.info(for: $0) },
                    gitFacts: { gitFacts.facts(for: $0) },
                    locale: locale
                ).rows.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let entries = WorktreeDropdownEntry.entries(of: project, in: sections, rows: rows)
            VStack(alignment: .leading, spacing: LimpidLayout.Supervision.popoverRowSpacing) {
                DropdownHeading(Text("Worktrees in \(project.name)"))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: LimpidLayout.Supervision.popoverRowSpacing) {
                            ForEach(entries) { entry in
                                WorktreeDropdownRow(
                                    entry: entry,
                                    row: rows[entry.container],
                                    pullRequestMark: PRMarkPresentation.supervisionStyle(for: prStatusStore.info(for: entry.container)),
                                    isCurrent: entry.container == window.selection.activeContainerID,
                                    isSelected: entry.container == selection.id,
                                    checkColor: SupervisionTokens.accentIcon(settings.settings.appearance.accentColor),
                                    // The pointer selects, so one row is lit:
                                    // the one Return opens.
                                    onHover: { selection.select(entry.container) },
                                    action: { open(entry.container) }
                                )
                                .id(entry.container)
                            }
                        }
                    }
                    .frame(maxHeight: FloatingPanelPlacement.scrollingBodyHeight(
                        preferred: 360,
                        cap: maxHeight,
                        chrome: panelHeight - listHeight
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    .onChange(of: selection.id) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
                DropdownSeparator()
                DropdownItem("New Worktree…") {
                    dismiss()
                    // The window's sheet opens for the project the window shows.
                    window.commands.send(.newWorktree)
                }
                .disabled(!CheckoutName.isRepository(project))
            }
            .padding(LimpidLayout.Supervision.dropdownPadding)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
            .dropdownListKeys(
                WorktreeDropdownEntry.choosable(entries),
                selection: $selection,
                start: window.selection.activeContainerID,
                choose: open
            )
        }
    }

    private func open(_ container: ContainerID) {
        session.setActiveContainer(container, in: window.id, intent: .person)
        dismiss()
    }
}

/// A checkout in the dropdown: a check on the one the window shows, the
/// name its sidebar row goes by, its branch (when the name is not it) and
/// folder under it with how many agents run there when more than one, and
/// its row's state glyph, after its pull request's mark when it has one.
/// A checkout the person labeled shows its branch and folder under the
/// label, as any row not named by its branch does; one with no branch
/// gives its folder's name in place of the path and keeps the full path in
/// its tooltip.
private struct WorktreeDropdownRow: View {
    let entry: WorktreeDropdownEntry
    /// The checkout's sidebar row; `nil` until the sidebar lists it.
    let row: SessionSidebarModel.Row?
    let pullRequestMark: PRMarkPresentation?
    let isCurrent: Bool
    /// The arrow keys' row, or the one under the pointer.
    let isSelected: Bool
    /// The accent, readable as an icon on the dropdown.
    let checkColor: Color
    let onHover: () -> Void
    let action: () -> Void
    @Environment(\.locale) private var locale

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Layout.spaceS) {
                DropdownCheckMark(isChecked: isCurrent, color: checkColor)
                    .frame(height: Layout.dropdownRowLineHeight)
                Image(systemName: ContainerSymbol.worktree)
                    .font(.supervision(.label))
                    .foregroundStyle(SupervisionTokens.muted.color)
                    .frame(width: Layout.dropdownIconColumnWidth, height: Layout.dropdownRowLineHeight)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Layout.popoverRowLineSpacing) {
                    HStack(spacing: Layout.spaceS) {
                        // In the sidebar row's face, as the row shows it.
                        Text(verbatim: entry.name)
                            .font(.supervision(.label, weight: .medium))
                            .foregroundStyle(SupervisionTokens.text.color)
                            .lineLimit(1)
                            .supervisionTruncation(entry.nameTruncation)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let row {
                            // The pull request attached before the state, so
                            // the state glyphs keep one column down the menu
                            // whether or not a checkout has a request.
                            if row.fact.pullRequest != nil, let pullRequestMark {
                                SessionPRMark(style: pullRequestMark, size: Layout.stateGlyphSize)
                            }
                            SessionStateGlyph(glyph: row.fact.glyph)
                                .frame(width: Layout.stateGlyphSize, height: Layout.stateGlyphSize)
                        }
                    }
                    .frame(height: Layout.dropdownRowLineHeight)
                    Text(verbatim: detail)
                        .font(.supervisionCode(beside: .row))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .lineLimit(1)
                        .supervisionTruncation(.path)
                }
            }
            .padding(Layout.dropdownRowInsets)
            .dropdownRowBackground(isSelected: isLit, isHovering: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A labeled checkout with no branch gives its folder's name in place
        // of the whole path, so the path is here; any other line shows it.
        .help(Text(verbatim: row?.checkout?.isBranch == false ? fullPath : ""))
        .disabled(entry.isMissing)
        .onHover { isHovering in
            if isHovering, !entry.isMissing {
                onHover()
            }
        }
        // Only the words are replaced, so the button keeps its press and
        // its disabled state for a folder gone from disk.
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// A folder gone from disk is never lit: it cannot be opened.
    private var isLit: Bool {
        isSelected && !entry.isMissing
    }

    /// This is the checkout's folder in full, with home abbreviated.
    private var fullPath: String {
        PathFormatting.abbreviateHome(entry.folder.path)
    }

    /// This is the branch when the name is not it, the folder, then "Agents
    /// 2" when the checkout runs more than one; for a labeled checkout with
    /// no branch, it is its folder's name.
    private var detail: String {
        WorktreeDropdownText.detail(
            name: entry.name,
            branch: entry.branch,
            folder: fullPath,
            shownFolder: row?.checkout.flatMap { $0.isBranch ? nil : $0.shown },
            agentCount: row?.agentCount ?? 0,
            locale: locale
        )
    }

    /// The name, the state its glyph shows, and the second line.
    private var spokenLabel: String {
        WorktreeDropdownText.spokenLabel(name: entry.name, row: row, detail: detail, locale: locale)
    }
}
