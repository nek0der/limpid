// ContainerSettingsSheet.swift
// Limpid — unified settings sheet for both Projects and Groups.
// Mirrors the Liquid Glass pattern of CreateWorktreeSheet
// (NavigationStack + Form + `.scrollContentBackground(.hidden)`) so the
// sheets feel like siblings. Auto-saves on every change — the only
// button is "Done".
//
// The sheet adapts to its `target`:
//   • Common (Project + Group): name, palette colour, Working Directory
//     (mode Picker + a path field shown only for the `.fixed` mode,
//     iTerm2-style).
//   • Project only: Root path, Worktrees placement, Hidden Worktrees.
//   • Group only: no extra sections — its cwd lives in the common block.

import AppKit
import SwiftUI

/// Which container the sheet is editing. Carrying the kind (rather than
/// a bare UUID) lets one sheet drive both the Project and Group entry
/// points from a single `.sheet(item:)`.
enum ContainerSettingsTarget: Identifiable, Equatable {
    case project(UUID)
    case group(UUID)

    var id: UUID {
        switch self {
        case let .project(id), let .group(id): id
        }
    }
}

struct ContainerSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WindowSession.self) private var session

    let target: ContainerSettingsTarget

    @State private var nameDraft: String = ""
    @State private var customParentText: String = ""
    @State private var paletteOpen: Bool = false

    /// Tag used by the placement Picker. We expand `WorktreePlacement`
    /// to a tag because `.custom(URL)` carries associated data and
    /// can't be directly tagged on a stable identity.
    private enum PlacementTag: Hashable {
        case siblingPrefixed, insideHidden, custom
    }

    private var projectID: UUID? {
        if case let .project(id) = target { return id }
        return nil
    }

    private var groupID: UUID? {
        if case let .group(id) = target { return id }
        return nil
    }

    private var project: Project? {
        projectID.flatMap { id in session.projects.first(where: { $0.id == id }) }
    }

    private var group: TabGroup? {
        groupID.flatMap { id in session.groups.first(where: { $0.id == id }) }
    }

    private var paletteIndex: Int? {
        project?.paletteIndex ?? group?.paletteIndex
    }

    private var currentTag: PlacementTag {
        switch project?.worktreePlacement ?? .siblingPrefixed {
        case .siblingPrefixed: .siblingPrefixed
        case .insideHidden: .insideHidden
        case .custom: .custom
        }
    }

    private var hiddenWorktrees: [Worktree] {
        project?.worktrees.filter(\.isHidden) ?? []
    }

    private var titleText: LocalizedStringResource {
        projectID != nil ? "Project Settings" : "Group Settings"
    }

    private var titleIcon: String {
        projectID != nil ? "folder.badge.gearshape" : "square.stack.3d.up"
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                if projectID != nil {
                    worktreesSection
                    if !hiddenWorktrees.isEmpty {
                        hiddenSection
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label {
                        Text(titleText)
                            .font(.system(size: 14, weight: .semibold))
                    } icon: {
                        Image(systemName: titleIcon)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 520, height: 520)
        .onAppear(perform: loadDrafts)
    }

    // MARK: - General (common: Project + Group)

    private var generalSection: some View {
        Section("General") {
            HStack {
                Text("Name")
                Spacer()
                TextField("", text: $nameDraft)
                    .multilineTextAlignment(.trailing)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 260)
                    .onSubmit { commitName() }
                    .onDisappear { commitName() }
            }
            HStack {
                Text("Color")
                Spacer()
                Button {
                    paletteOpen.toggle()
                } label: {
                    Circle()
                        .fill(LimpidColor.paletteColor(paletteIndex))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $paletteOpen, arrowEdge: .bottom) {
                    ContainerColorPicker(current: paletteIndex) { idx in
                        applyPaletteIndex(idx)
                        paletteOpen = false
                    }
                }
            }
            if let project {
                LabeledContent("Root") {
                    Text(project.rootURL.path)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            // Working Directory only applies to Groups. Project tabs
            // already derive their cwd from the project root / worktree,
            // so a mode Picker there would be redundant.
            if groupID != nil {
                WorkingDirectoryField(
                    label: "Working Directory",
                    mode: groupCwdModeBinding,
                    path: groupCwdPathBinding
                )
            }
        }
    }

    // MARK: - Working Directory (Group)

    //
    // The shared `WorkingDirectoryField` drives two independent
    // bindings; we route both through `setGroupCwdMode` (which
    // auto-saves and keeps mode/path consistent) by combining each
    // write with the group's other current value.

    private var groupCwdModeBinding: Binding<WorkingDirectoryMode> {
        Binding(
            get: { group?.cwdMode ?? .inheritPrevious },
            set: { newMode in
                guard let groupID else { return }
                session.setGroupCwdMode(groupID, to: newMode, path: group?.cwdPath)
            }
        )
    }

    private var groupCwdPathBinding: Binding<URL?> {
        Binding(
            get: { group?.cwdPath },
            set: { newPath in
                guard let groupID else { return }
                session.setGroupCwdMode(groupID, to: group?.cwdMode ?? .fixed, path: newPath)
            }
        )
    }

    // MARK: - Worktrees (Project only)

    private var worktreesSection: some View {
        Section {
            Picker("Placement", selection: Binding(
                get: { currentTag },
                set: { applyPlacementTag($0) }
            )) {
                Text("Adjacent Folder (\(siblingPreview))").tag(PlacementTag.siblingPrefixed)
                Text("Inside project (.worktrees/)").tag(PlacementTag.insideHidden)
                Text("Custom Parent Folder").tag(PlacementTag.custom)
            }
            if currentTag == .custom {
                LabeledContent("Parent folder") {
                    HStack(spacing: 8) {
                        Button {
                            chooseCustomParent()
                        } label: {
                            Label {
                                Text(displayCustomParent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "folder")
                            }
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.regular)
                    }
                }
            }
            LabeledContent("Preview") {
                Text(placementPreviewPath)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Worktrees")
        } footer: {
            Text(
                """
                Used for new worktrees created from this project. \
                Applies to future creations only — existing worktrees stay where they are.
                """
            )
        }
    }

    /// Sample sibling folder name like "myapp-<branch>", used in the
    /// Picker label so the user can see the convention at a glance.
    private var siblingPreview: String {
        guard let project else { return "<repo>-<branch>" }
        return "\(project.rootURL.lastPathComponent)-<branch>"
    }

    /// Preview of the path a new worktree would land at, using a
    /// placeholder branch leaf so the user can sanity-check the
    /// strategy without filling the Create sheet first.
    private var placementPreviewPath: String {
        guard let project else { return "—" }
        return PathFormatting.abbreviateHome(
            project.resolvedWorktreeURL(branchLeaf: "<branch>").path
        )
    }

    private var displayCustomParent: String {
        let trimmed = customParentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return String(localized: "Choose…")
        }
        return PathFormatting.abbreviateHome(trimmed)
    }

    // MARK: - Hidden Worktrees (Project only)

    private var hiddenSection: some View {
        Section {
            ForEach(hiddenWorktrees) { wt in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text(wt.label)
                    Spacer()
                    Button("Show") {
                        if let projectID {
                            session.unhideWorktree(projectID: projectID, worktreeID: wt.id)
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if hiddenWorktrees.count > 1 {
                Button("Show All") {
                    if let projectID {
                        session.unhideAllWorktrees(projectID: projectID)
                    }
                }
            }
        } header: {
            Text("Hidden Worktrees (\(hiddenWorktrees.count))")
        }
    }

    // MARK: - Persistence helpers

    private func loadDrafts() {
        if let project {
            nameDraft = project.name
            if case let .custom(url) = project.worktreePlacement {
                customParentText = url.path
            } else {
                customParentText = ""
            }
        } else if let group {
            nameDraft = group.name
        }
    }

    private var currentName: String? {
        project?.name ?? group?.name
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentName else { return }
        if let projectID {
            session.renameProject(projectID, to: trimmed)
        } else if let groupID {
            session.renameGroup(groupID, to: trimmed)
        }
    }

    private func applyPaletteIndex(_ idx: Int) {
        if let projectID {
            session.setProjectPaletteIndex(projectID, to: idx)
        } else if let groupID {
            session.setGroupPaletteIndex(groupID, to: idx)
        }
    }

    // MARK: - Worktree placement mutations (Project)

    private func applyPlacementTag(_ tag: PlacementTag) {
        guard let projectID else { return }
        switch tag {
        case .siblingPrefixed:
            session.setProjectWorktreePlacement(projectID, to: .siblingPrefixed)
        case .insideHidden:
            session.setProjectWorktreePlacement(projectID, to: .insideHidden)
        case .custom:
            let trimmed = customParentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                // No parent picked yet — open the picker so the user
                // can choose one. If they cancel, we keep the previous
                // placement (no transition happens until a URL is set).
                chooseCustomParent()
            } else {
                let expanded = (trimmed as NSString).expandingTildeInPath
                session.setProjectWorktreePlacement(
                    projectID,
                    to: .custom(URL(fileURLWithPath: expanded))
                )
            }
        }
    }

    private func chooseCustomParent() {
        guard let projectID else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose")
        if !customParentText.isEmpty {
            panel.directoryURL = URL(
                fileURLWithPath: (customParentText as NSString).expandingTildeInPath
            )
        }
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        customParentText = chosen.path
        session.setProjectWorktreePlacement(projectID, to: .custom(chosen))
    }
}
