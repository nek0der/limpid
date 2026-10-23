// WorktreePlacementActions.swift
// Limpid — the worktree placement choices that the project settings and the new worktree sheet both offer.

import AppKit
import Foundation

/// Where a project's new worktrees go (`WorktreePlacement`), as the
/// folder menu of Project Settings and of the new worktree sheet offers
/// it. Both change the project's setting through here, so a choice made in
/// either sheet behaves the same, the folder panel included.
@MainActor
enum WorktreePlacementActions {
    /// A placement as the menu lists it. `.custom` carries its folder,
    /// which a menu item cannot: the folder comes
    /// from what the sheet remembers, or from the panel.
    enum Choice: Hashable, CaseIterable, Sendable {
        case siblingPrefixed
        case insideHidden
        case custom
    }

    nonisolated static func choice(of placement: WorktreePlacement) -> Choice {
        switch placement {
        case .siblingPrefixed: .siblingPrefixed
        case .insideHidden: .insideHidden
        case .custom: .custom
        }
    }

    /// The placement a choice sets without asking anything. `customParent`
    /// is the folder the custom placement had or was last given, a path
    /// that may start with `~`; `nil` when the choice is custom and there
    /// is no folder yet, which the panel has to answer first.
    nonisolated static func placement(for choice: Choice, customParent: String) -> WorktreePlacement? {
        switch choice {
        case .siblingPrefixed:
            return .siblingPrefixed
        case .insideHidden:
            return .insideHidden
        case .custom:
            let trimmed = customParent.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return .custom(URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
        }
    }

    /// The custom placement's folder, as `placement(for:customParent:)`
    /// takes it back; empty for the other placements.
    nonisolated static func customParent(of placement: WorktreePlacement) -> String {
        if case let .custom(url) = placement {
            return url.path
        }
        return ""
    }

    /// The inside placement's name, one key for both sheets.
    nonisolated static let insideTitle = LocalizedStringResource(
        "Inside the Project (.worktrees/)",
        comment: "Worktree placement inside the project's own folder: Project Settings' picker and the new worktree sheet's folder menu"
    )

    /// A placement's short name, for a menu button's face: the items stay
    /// long, with what each makes of the path. A chosen folder goes by its
    /// own name, which no translation changes.
    nonisolated static func shortTitle(of placement: WorktreePlacement) -> DisplayText {
        switch placement {
        case .siblingPrefixed:
            .localized(LocalizedStringResource(
                "Next to the Project",
                comment: "New worktree sheet: the folder menu's face for the folder beside the project's"
            ))
        case .insideHidden:
            .localized(LocalizedStringResource(
                "Inside the Project",
                comment: "New worktree sheet: the folder menu's face for the folder inside the project"
            ))
        case let .custom(folder):
            .verbatim(folder.lastPathComponent)
        }
    }

    /// The sibling placement's folder name with a branch's place held, so
    /// the choice shows the convention at a glance: "myapp-<branch>".
    nonisolated static func siblingPreview(of project: Project?) -> String {
        guard let project else { return "<repo>-<branch>" }
        return "\(project.rootURL.lastPathComponent)-<branch>"
    }

    /// Sets the project's placement to `choice`. A custom choice with no
    /// folder yet opens the panel; canceled, the placement stays as it
    /// was, since there is nothing to change it to. `onChosen` hears the
    /// folder the panel gave, for a sheet that shows it. `window` is the
    /// sheet the choice was made in, which the panel hangs from.
    static func apply(
        _ choice: Choice,
        customParent: String,
        to projectID: UUID,
        in session: WorkspaceSession,
        attachedTo window: NSWindow?,
        onChosen: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        if let placement = placement(for: choice, customParent: customParent) {
            session.setProjectWorktreePlacement(projectID, to: placement)
        } else {
            chooseCustomParent(startingAt: customParent, for: projectID, in: session, attachedTo: window, onChosen: onChosen)
        }
    }

    /// Asks for the custom placement's folder and sets it. The panel opens
    /// at `startingAt` when there is one, so choosing again starts from the
    /// folder in use.
    static func chooseCustomParent(
        startingAt: String,
        for projectID: UUID,
        in session: WorkspaceSession,
        attachedTo window: NSWindow?,
        onChosen: @escaping @MainActor (URL) -> Void = { _ in }
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        // AppKit localizes the open panel's own buttons and sidebar in the
        // language the process launched with, so our prompt does too: a
        // panel half in each language would read worse than one that waits
        // for the relaunch the menu bar also waits for.
        // swiftlint:disable:next launch_language_lookup
        panel.prompt = String(localized: "Choose")
        if !startingAt.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (startingAt as NSString).expandingTildeInPath)
        }
        // Attached to the sheet it was asked from, which the caller names
        // (`HostWindowReader`) rather than this guessing the key window:
        // that sheet waits for the answer, so its ⌘⏎ cannot create while
        // the folder is still being chosen, and closing it first cannot
        // change the placement behind it. Never a free-standing panel over
        // a sheet, and never a second sheet of our own. Free-standing only
        // when the caller is in no window yet. Non-blocking either way;
        // same stutter rationale as `WorkingDirectoryField.chooseDirectory`.
        if let window {
            panel.beginSheetModal(for: window) { response in
                finishChoosing(response, in: panel, for: projectID, in: session, onChosen: onChosen)
            }
        } else {
            panel.begin { response in
                finishChoosing(response, in: panel, for: projectID, in: session, onChosen: onChosen)
            }
        }
    }

    private static func finishChoosing(
        _ response: NSApplication.ModalResponse,
        in panel: NSOpenPanel,
        for projectID: UUID,
        in session: WorkspaceSession,
        onChosen: @MainActor (URL) -> Void
    ) {
        guard response == .OK, let chosen = panel.url else { return }
        session.setProjectWorktreePlacement(projectID, to: .custom(chosen))
        onChosen(chosen)
    }
}
