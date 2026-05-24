// ProjectSettingsSheet.swift
// Limpid — per-project settings sheet. Mirrors the Liquid Glass
// pattern of CreateWorktreeSheet (NavigationStack + Form +
// `.scrollContentBackground(.hidden)`) so the two sheets feel like
// siblings. Auto-saves on every change — the only button is "Done".
//
// Sections:
//   1. General        — project name, palette colour, root path
//   2. Worktrees      — placement strategy for `git worktree add`
//                       (sibling / inside-hidden / custom parent)
//   3. Hidden Worktrees — list of rows the user hid from the sidebar
//                         with one-click "Show" per row + "Show All"

import AppKit
import SwiftUI

struct ProjectSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(WindowSession.self) private var session

    let projectID: UUID

    @State private var nameDraft: String = ""
    @State private var customParentText: String = ""
    @State private var paletteOpen: Bool = false

    /// Tag used by the placement Picker. We expand `WorktreePlacement`
    /// to a tag because `.custom(URL)` carries associated data and
    /// can't be directly tagged on a stable identity.
    private enum PlacementTag: Hashable {
        case siblingPrefixed, insideHidden, custom
    }

    private var currentTag: PlacementTag {
        switch project?.worktreePlacement ?? .siblingPrefixed {
        case .siblingPrefixed: .siblingPrefixed
        case .insideHidden: .insideHidden
        case .custom: .custom
        }
    }

    private var project: Project? {
        session.projects.first(where: { $0.id == projectID })
    }

    private var hiddenWorktrees: [Worktree] {
        project?.worktrees.filter(\.isHidden) ?? []
    }

    var body: some View {
        NavigationStack {
            Form {
                generalSection
                worktreesSection
                if !hiddenWorktrees.isEmpty {
                    hiddenSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Label {
                        Text("Project Settings")
                            .font(.system(size: 14, weight: .semibold))
                    } icon: {
                        Image(systemName: "folder.badge.gearshape")
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

    // MARK: - General

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
                    .onChange(of: nameDraft) { _, _ in
                        // Commit lazily on blur so each keystroke
                        // isn't a persistence event, but reflect
                        // immediately to the UI via the draft.
                    }
                    .onDisappear { commitName() }
            }
            HStack {
                Text("Color")
                Spacer()
                Button {
                    paletteOpen.toggle()
                } label: {
                    Circle()
                        .fill(LimpidColor.paletteColor(project?.paletteIndex))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $paletteOpen, arrowEdge: .bottom) {
                    ContainerColorPicker(current: project?.paletteIndex) { idx in
                        session.setProjectPaletteIndex(projectID, to: idx)
                        paletteOpen = false
                    }
                }
            }
            LabeledContent("Root") {
                if let project {
                    Text(project.rootURL.path)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: - Worktrees

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
                "Used for new worktrees created from this project. Applies to future creations only — existing worktrees stay where they are."
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

    // MARK: - Hidden Worktrees

    private var hiddenSection: some View {
        Section {
            ForEach(hiddenWorktrees) { wt in
                HStack {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                    Text(wt.label)
                    Spacer()
                    Button("Show") {
                        session.unhideWorktree(projectID: projectID, worktreeID: wt.id)
                    }
                    .buttonStyle(.borderless)
                }
            }
            if hiddenWorktrees.count > 1 {
                Button("Show All") {
                    session.unhideAllWorktrees(projectID: projectID)
                }
            }
        } header: {
            Text("Hidden Worktrees (\(hiddenWorktrees.count))")
        }
    }

    // MARK: - Persistence helpers

    private func loadDrafts() {
        guard let project else { return }
        nameDraft = project.name
        if case let .custom(url) = project.worktreePlacement {
            customParentText = url.path
        } else {
            customParentText = ""
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != project?.name else { return }
        session.renameProject(projectID, to: trimmed)
    }

    private func applyPlacementTag(_ tag: PlacementTag) {
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
