// ProjectMenuButton.swift
// Limpid — the title bar's project ▾ and the dropdown it opens.

import AppKit
import SwiftUI

/// Names the project this window shows, behind its mark, and opens the
/// project dropdown. A dot after the name says another project has
/// something that needs attention, for a window whose sidebar is hidden or
/// folds those projects.
struct ProjectMenuButton: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(ProjectWindowState.self) private var window
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(\.locale) private var locale

    /// The window's project, kept while a scratch tab is selected: the same
    /// one the sidebar lists and ⌘J starts from.
    private var currentProject: Project? {
        window.selection.shownProjectID.flatMap { session.project($0) }
    }

    var body: some View {
        let others = NeedsAttentionPillModel(attentionQueue.queue.counts(inProjectsOtherThan: currentProject?.id))
        TitleBarMenuButton(menu: .project) { isHighlighted in
            TitleBarMenuLabel(title: title, isHighlighted: isHighlighted, textStyle: .title) {
                if let project = currentProject {
                    ProjectAvatar(name: project.name, paletteIndex: project.paletteIndex)
                }
            } trailing: {
                OtherProjectsMark(style: others.style)
            }
        }
        .help(Text(verbatim: ProjectMenuModel.controlHelp(otherProjectsCount: others.count, locale: locale)))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityHint(Text(
            "Shows the projects to switch to",
            comment: "Title bar, VoiceOver: what the project dropdown's button opens"
        ))
        .accessibilityValue(others.style == .empty ? Text(verbatim: "") : Text("Other projects need attention"))
    }

    /// A window that shows nothing names the app, as its title does.
    private var title: String {
        if window.selection.isChoosingProject {
            return "Limpid"
        }
        return currentProject?.name ?? session.containerLabel(for: window.selection.activeContainerID, locale: locale)
    }
}

/// A project's mark: its two initials in white on its palette color, a
/// square with rounded corners, the color darkened where white would not
/// read on it (`ProjectMarkRule`). The letters are SF Pro, unlike an agent
/// badge's monospaced ones, so the two kinds of mark are not mistaken for
/// each other. The name beside it says the same, so VoiceOver skips it.
struct ProjectAvatar: View {
    enum Size {
        /// The title bar's project control.
        case regular
        /// A row of the project dropdown, a step larger so the list reads
        /// by its marks.
        case large
        /// A project's header in the sidebar, a step smaller, as its name
        /// is a row's size rather than the title's.
        case header

        var side: CGFloat {
            switch self {
            case .regular: LimpidLayout.Supervision.projectAvatarSize
            case .large: LimpidLayout.Supervision.dropdownProjectAvatarSize
            case .header: LimpidLayout.Supervision.sidebarProjectAvatarSize
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .regular: LimpidLayout.Supervision.projectAvatarCornerRadius
            case .large: LimpidLayout.Supervision.dropdownProjectAvatarCornerRadius
            case .header: LimpidLayout.Supervision.projectAvatarCornerRadius
            }
        }

        var fontSize: LimpidFont.Supervision.Size {
            switch self {
            case .regular: .badge
            case .large: .caption
            case .header: .glyph
            }
        }
    }

    let name: String
    let paletteIndex: Int?
    var size = Size.regular

    var body: some View {
        let fill = SupervisionTokens.projectMarkFill(paletteIndex: paletteIndex)
        // The same two letters at every size, so a project's mark in the
        // dropdown and the sidebar is the one on the control.
        RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            .fill(fill)
            .frame(width: size.side, height: size.side)
            .overlay {
                // Spaced a fiftieth of their size apart.
                Text(verbatim: ProjectMenuModel.initials(of: name))
                    .font(.supervision(size.fontSize, weight: .bold))
                    .tracking(size.fontSize.rawValue / 50)
                    .foregroundStyle(Color(nsColor: ProjectMarkRule.label.nsColor))
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
    }
}

/// The dot after the project's name: amber when another project has
/// something blocked on the person, blue when only unread turns. The
/// button's VoiceOver value says the same in words.
private struct OtherProjectsMark: View {
    let style: NeedsAttentionPillModel.Style

    var body: some View {
        switch style {
        case .blocking:
            dot(SupervisionTokens.waiting.color)
        case .unreadOnly:
            dot(SupervisionTokens.unread.color)
        case .empty:
            EmptyView()
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: LimpidLayout.Supervision.otherProjectsDotSize, height: LimpidLayout.Supervision.otherProjectsDotSize)
            .accessibilityHidden(true)
    }
}

/// Search, the projects with their counts in the sidebar's order, Open Folder…, and the
/// current project's settings, folder, and Close Project…. ↑↓ move through
/// the projects from the search field and Return opens the selected one.
struct ProjectDropdown: View {
    let onOpenSettings: (UUID) -> Void
    /// Asks to close the project: the confirmation is raised by the host,
    /// so it stays up after the dropdown closes.
    let onCloseProject: (UUID) -> Void
    /// Closes the dropdown and hands the keyboard back to the terminal.
    let dismiss: () -> Void
    /// This is the tallest the dropdown may be under its control: the list gives
    /// up height to it, so Open Folder… and Close Project… stay in a
    /// short window.
    let maxHeight: CGFloat
    @Environment(WorkspaceSession.self) private var session
    @Environment(AttentionQueueStore.self) private var attentionQueue
    @Environment(AttentionState.self) private var attention
    @Environment(ProjectWindowState.self) private var window
    @Environment(WindowRegistry.self) private var registry
    @Environment(SettingsStore.self) private var settings
    @Environment(\.frecencyStore) private var frecencyStore
    @Environment(\.popoverSurface.ground) private var ground
    @State private var query = ""
    @State private var selectedID: UUID?
    @FocusState private var isSearchFocused: Bool
    /// These are the dropdown's measured height and its list's
    /// (`listHeight`): the rest is their difference, and the list gets what
    /// `maxHeight` leaves after the rest
    /// (`FloatingPanelPlacement.scrollingBodyHeight`).
    @State private var panelHeight: CGFloat = 0
    @State private var listHeight: CGFloat = 0

    private var currentProjectID: UUID? {
        window.selection.shownProjectID
    }

    var body: some View {
        let rows = ProjectMenuModel(
            session: session,
            registry: registry,
            window: window.selection,
            query: query,
            attentionQueue: attentionQueue.queue,
            attention: attention
        ).rows
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.popoverRowSpacing) {
            TextField("", text: $query, prompt: Text("Search Projects").foregroundStyle(SupervisionTokens.muted.color))
                .textFieldStyle(.plain)
                .font(.supervision(.icon))
                .searchFieldFace(.dropdown(well: ground.well.color), showsRing: isSearchFocused)
                .accessibilityLabel(Text("Search Projects"))
                .focused($isSearchFocused)
                .onSubmit { selectedID.map { open($0) } }
                // ⌘Return opens the selected project in a new window.
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.chord == .command, let selectedID else { return .ignored }
                    open(selectedID, opensInNewWindow: true)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    move(forward: true, in: rows)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    move(forward: false, in: rows)
                    return .handled
                }
                // Further in than the rows, so its focus ring keeps clear
                // of the dropdown's edge.
                .padding(LimpidLayout.Supervision.popoverFieldMargins)
            // In the sidebar's order, not by use.
            DropdownHeading(Text(ProjectListText.heading))
            if rows.isEmpty {
                SupervisionEmptyState(.noResults, size: .compact)
                    // The rule under it keeps a step of its own over the
                    // block's bottom inset; as much again over the symbol,
                    // so the block sits midway between heading and rule.
                    .padding(.top, LimpidLayout.Supervision.spaceS)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: LimpidLayout.Supervision.popoverRowSpacing) {
                            ForEach(rows) { row in
                                ProjectDropdownRow(
                                    row: row,
                                    isSelected: row.id == selectedID,
                                    checkColor: SupervisionTokens.accentIcon(settings.settings.appearance.accentColor),
                                    action: { open(row.id, opensInNewWindow: $0) }
                                )
                                .id(row.id)
                            }
                        }
                    }
                    .frame(maxHeight: FloatingPanelPlacement.scrollingBodyHeight(
                        preferred: 320,
                        cap: maxHeight,
                        chrome: panelHeight - listHeight
                    ))
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                    .onChange(of: selectedID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id)
                    }
                }
            }
            DropdownSeparator()
            DropdownItem(
                "Open Folder…",
                shortcut: settings.settings.keyboard.shortcut(for: .openFolder)?.displayString
            ) {
                dismiss()
                SupervisionWindowActions.openFolder(from: window, session: session, registry: registry, frecency: frecencyStore)
            }
            if let currentProjectID, let project = session.project(currentProjectID) {
                DropdownSeparator()
                ForEach(ProjectMenuModel.projectItems(for: currentProjectID, in: session.projects), id: \.self) { item in
                    switch item {
                    case .settings:
                        DropdownItem("Project Settings…") {
                            dismiss()
                            onOpenSettings(currentProjectID)
                        }
                    case .revealInFinder:
                        DropdownItem("Show in Finder") {
                            dismiss()
                            NSWorkspace.shared.activateFileViewerSelecting([project.rootURL])
                        }
                    case .close:
                        // Apart from the two above: it is the one that
                        // takes the project out of Limpid.
                        DropdownSeparator()
                        DropdownItem("Close Project…") {
                            dismiss()
                            onCloseProject(currentProjectID)
                        }
                    }
                }
            }
        }
        .padding(LimpidLayout.Supervision.dropdownPadding)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        .onAppear {
            selectedID = rows.first?.id
            KeyboardHandoff.afterResponderSettles { isSearchFocused = true }
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            // The search narrowed the list: keep the selection on a row
            // that is still there, or start again from the top.
            if !ids.contains(where: { $0 == selectedID }) {
                selectedID = ids.first
            }
        }
    }

    private func move(forward: Bool, in rows: [ProjectMenuModel.Row]) {
        let index = rows.firstIndex { $0.id == selectedID }
        guard let next = ListKeyboardStep.index(from: index, count: rows.count, forward: forward) else { return }
        selectedID = rows[next].id
    }

    /// Choosing the project already shown does nothing, with ⌘ or
    /// without. Another one switches this window to it in place:
    /// back on what it showed last, or on the session last used there, or
    /// on the project with nothing open when it has no session yet. With
    /// ⌘ (`opensInNewWindow`) it opens in a new window instead
    /// (`WindowRegistry.openInNewWindow`). A project another window shows
    /// brings that window forward either way.
    private func open(_ projectID: UUID, opensInNewWindow: Bool = false) {
        dismiss()
        guard projectID != currentProjectID else { return }
        // The palette's project rows count toward the same order.
        frecencyStore?.record(ProjectMenuModel.frecencyKey(projectID))
        if opensInNewWindow {
            registry.openInNewWindow(project: projectID, in: session, from: window)
        } else {
            registry.show(project: projectID, in: session, from: window, intent: .person)
        }
    }
}

/// A project in the dropdown: a check on the current one, its mark, its
/// name, and its counts in chips. The arrow keys' row and the hovered one
/// take the same fill.
private struct ProjectDropdownRow: View {
    let row: ProjectMenuModel.Row
    let isSelected: Bool
    /// The accent, readable as an icon on the dropdown.
    let checkColor: Color
    /// Opens the row; `true` in a new window (⌘-click, or VoiceOver's
    /// "Open in New Window").
    let action: (_ opensInNewWindow: Bool) -> Void
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    private typealias Layout = LimpidLayout.Supervision

    var body: some View {
        // A Button, so the keyboard and VoiceOver can press it: only a
        // click reads ⌘ (`NewWindowModifier.isCommandClick`).
        Button { action(NewWindowModifier.isCommandClick) } label: {
            HStack(spacing: Layout.dropdownRowSpacing) {
                DropdownCheckMark(isChecked: row.isCurrent, color: checkColor)
                ProjectAvatar(name: row.name, paletteIndex: row.paletteIndex, size: .large)
                HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
                    Text(verbatim: row.name)
                        .font(.supervision(.label, weight: .semibold))
                        .foregroundStyle(SupervisionTokens.text.color)
                        .lineLimit(1)
                        .supervisionTruncation(.name)
                    // Choosing it brings that window forward rather than
                    // switching this one; said faintly, after the
                    // name, which a narrow row cuts first.
                    if row.isInOtherWindow {
                        Text("Other Window", comment: "Another window shows this project: choosing it brings that window forward")
                            .font(.supervision(.row))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Each count says what it counts, in words, rather than
                // leaving a bare number to its color.
                HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
                    if row.attention.count > 0 {
                        SupervisionChip(
                            text: Text(row.attention.label),
                            tone: row.attention.style == .blocking ? .waiting : .unread
                        )
                    }
                    if row.running > 0 {
                        SupervisionChip(text: Text("Running · \(row.running)"), tone: .running)
                    }
                }
                // The counts stay whole; the name is what a narrow row cuts.
                .fixedSize()
            }
            .padding(Layout.dropdownRowInsets)
            .dropdownRowBackground(isSelected: isSelected, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .modifier(RowHelp(text: ProjectMenuModel.rowHelp(row, locale: locale)))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        // VoiceOver's press opens the row here, never as a ⌘-click read
        // from an event kept from earlier; a new window is its own action.
        .accessibilityAction { action(false) }
        .accessibilityActions {
            if row.opensInNewWindow {
                Button { action(true) } label: { Text(NewWindowText.actionName) }
            }
        }
    }
}

/// A row's tooltip, only where it has one to give: an empty `.help` still
/// installs a tooltip on the row.
private struct RowHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content.help(Text(verbatim: text))
        } else {
            content
        }
    }
}
