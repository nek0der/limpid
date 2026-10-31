// WorktreePlacementMenuItems.swift
// Weir — the worktree placement menu's items, one list for Project Settings and the new worktree sheet.

import SwiftUI

/// The placements, the one in use checked: the two fixed ones, then the
/// chosen folder while it is the placement, named by its path. "Choose a
/// Folder…" is an action, apart and never checked, as a save panel's
/// "Other…" is. Both sheets build their menu from this, so the same value
/// is chosen the same way wherever it is changed.
struct WorktreePlacementMenuItems: View {
    let project: Project?
    let onChoose: (WorktreePlacementActions.Choice) -> Void
    let onChooseFolder: () -> Void

    var body: some View {
        item(.siblingPrefixed, Text("Next to the Project (\(WorktreePlacementActions.siblingPreview(of: project)))"))
        item(.insideHidden, Text(WorktreePlacementActions.insideTitle))
        if let project, case let .custom(folder) = project.worktreePlacement {
            item(.custom, Text(verbatim: PathFormatting.abbreviateHome(folder.path)))
        }
        Divider()
        Button {
            onChooseFolder()
        } label: {
            Text(
                "Choose a Folder…",
                comment: "New worktree sheet: the folder menu's item that asks for the folder new worktrees go in"
            )
        }
    }

    /// One placement, checked while it is the project's. The toggle is the
    /// menu's checkmark, so VoiceOver reads it as selected; whichever way it
    /// flips, choosing the item applies it, and the folder in use is applied
    /// again as it is.
    private func item(_ choice: WorktreePlacementActions.Choice, _ title: Text) -> some View {
        Toggle(isOn: Binding(
            get: { project.map { WorktreePlacementActions.choice(of: $0.worktreePlacement) } == choice },
            set: { _ in onChoose(choice) }
        )) {
            title
        }
    }
}
