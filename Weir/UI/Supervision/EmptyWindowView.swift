// EmptyWindowView.swift
// Weir — what a window that shows nothing draws where the session would be: the projects to open.

import SwiftUI

/// The body of a window that shows nothing
/// (`WindowSelection.isChoosingProject`): "Open a Project", the projects no
/// window shows in the sidebar's order, and Open Folder…. Choosing a project shows
/// it in this window; the sidebar's scratch row shows the scratch tabs
/// instead. Nothing here is a terminal, so no pane is drawn or reported
/// until the person chooses.
struct EmptyWindowView: View {
    @Environment(WorkspaceSession.self) private var session
    @Environment(WindowRegistry.self) private var registry
    @Environment(ProjectWindowState.self) private var window
    @Environment(SettingsStore.self) private var settings
    @Environment(\.frecencyStore) private var frecencyStore

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        let model = EmptyWindowModel(session: session, window: window.selection)
        VStack(alignment: .leading, spacing: Layout.popoverRowSpacing) {
            Text("Open a Project", comment: "A window that shows nothing: the heading over the projects it can open")
                .font(.supervision(.heading, weight: .semibold))
                .foregroundStyle(SupervisionTokens.text.color)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, Layout.spaceS)
            if !model.rows.isEmpty {
                // In the sidebar's order, as project ▾ lists them.
                DropdownHeading(Text(ProjectListText.heading))
                ScrollView {
                    VStack(spacing: Layout.popoverRowSpacing) {
                        ForEach(model.rows) { row in
                            EmptyWindowProjectRow(row: row) { open(row.id) }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
                DropdownSeparator()
            }
            DropdownItem(
                "Open Folder…",
                shortcut: settings.settings.keyboard.shortcut(for: .openFolder)?.displayString
            ) {
                SupervisionWindowActions.openFolder(from: window, session: session, registry: registry, frecency: frecencyStore)
            }
        }
        .frame(width: WeirLayout.Supervision.emptyWindowColumnWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Shows the project in this window, as project ▾ does from a window
    /// that shows one (`WindowRegistry.show(project:in:from:intent:)`).
    private func open(_ projectID: UUID) {
        frecencyStore?.record(ProjectMenuModel.frecencyKey(projectID))
        registry.show(project: projectID, in: session, from: window, intent: .person)
    }
}

/// A project to open: its mark, its name, and its folder.
private struct EmptyWindowProjectRow: View {
    let row: EmptyWindowModel.Row
    let action: () -> Void
    @State private var isHovering = false

    private typealias Layout = WeirLayout.Supervision

    var body: some View {
        Button(action: action) {
            HStack(spacing: Layout.dropdownRowSpacing) {
                ProjectAvatar(name: row.name, paletteIndex: row.paletteIndex, size: .large)
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceHairline) {
                    Text(verbatim: row.name)
                        .font(.supervision(.label, weight: .semibold))
                        .foregroundStyle(SupervisionTokens.text.color)
                    Text(verbatim: row.folder)
                        .font(.supervision(.meta))
                        .foregroundStyle(SupervisionTokens.muted.color)
                        .supervisionTruncation(.path)
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Layout.dropdownRowInsets)
            .dropdownRowBackground(isSelected: false, isHovering: isHovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(Text(verbatim: row.folder))
        .accessibilityElement(children: .combine)
    }
}
