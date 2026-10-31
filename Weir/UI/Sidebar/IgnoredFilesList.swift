// IgnoredFilesList.swift
// Weir — Project Settings' list of the files Git ignores that each new worktree gets a copy of, and the menu that picks them.

import SwiftUI

extension IgnoredFilesDraft: EditableRowsDraft {
    var rowItems: [EditableRowItem] {
        rows.map { EditableRowItem(id: $0.id, text: $0.text) }
    }

    mutating func addRow() -> UUID {
        add()
    }

    mutating func removeRow(_ id: UUID) {
        remove(id)
    }

    mutating func setRowText(_ text: String, of id: UUID) {
        setText(text, of: id)
    }

    func rowProblem(of id: UUID, editing: UUID?) -> Problem? {
        problem(of: id, editing: editing)
    }
}

/// The files to copy as a list of paths and patterns, edited as the
/// test commands are, with "Choose from Ignored Files…" at the end of its
/// bar: what Git ignores in the project's folder, read as the section
/// shows, each checked while a row names it.
struct IgnoredFilesList: View {
    @Binding var draft: IgnoredFilesDraft
    /// The project's folder, whose ignored files the menu lists.
    let root: URL?
    var git: any GitRunning = LiveGit()

    /// What Git ignores in the folder, as it listed it.
    @State private var ignored: [String] = []

    /// The most the menu lists: a folder of build output can hold
    /// thousands, and a menu that long is no choice.
    private static let menuLimit = 100

    var body: some View {
        EditableRowList(draft: $draft, text: EditableRowListText(
            // A path, the same in every language.
            placeholder: Text(verbatim: ".env"),
            rowLabel: ProjectSettingsText.filesToCopy,
            empty: .noFilesToCopy,
            add: LocalizedStringResource("Add File", comment: "Project settings: the ＋ under the list of the files to copy"),
            remove: LocalizedStringResource("Remove File", comment: "Project settings: the − under the list of the files to copy"),
            reason: Self.reason
        )) {
            Menu {
                ForEach(ignored.prefix(Self.menuLimit), id: \.self) { path in
                    Toggle(isOn: Binding(
                        get: { draft.contains(path) },
                        set: { _ in draft.toggle(path) }
                    )) {
                        Text(verbatim: path)
                    }
                }
            } label: {
                Text(LocalizedStringResource(
                    "Choose from Ignored Files…",
                    comment: "Project settings: the menu of the files Git ignores in the project's folder, to copy into new worktrees"
                ))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(ignored.isEmpty)
        }
        .task(id: root) {
            guard let root else { return }
            ignored = await (try? git.listIgnored(repoRoot: root)) ?? []
        }
    }

    static func reason(_ problem: IgnoredFilesDraft.Problem) -> LocalizedStringResource {
        switch problem {
        case .empty:
            LocalizedStringResource(
                "An empty row isn’t saved.",
                comment: "Project settings: why a row of a list is not saved"
            )
        case .duplicate:
            LocalizedStringResource(
                "This file is already in the list, so this row isn’t saved.",
                comment: "Project settings: why a row of the files to copy is not saved"
            )
        case .unsafe:
            LocalizedStringResource(
                "Only paths inside the project’s folder, outside .git, are copied, so this row isn’t saved.",
                comment: "Project settings: why a row of the files to copy is not saved: absolute, with .., or naming .git"
            )
        }
    }
}
