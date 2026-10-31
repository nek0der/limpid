// TestCommandsList.swift
// Weir — Project Settings' editable lists (one monospaced field per row, with ＋ and −) and the test command list built on them.

import SwiftUI

/// A list Project Settings edits row by row (`CheckCommandsDraft`,
/// `IgnoredFilesDraft`): what `EditableRowList` needs of it.
protocol EditableRowsDraft {
    associatedtype Problem
    var rowItems: [EditableRowItem] { get }
    mutating func addRow() -> UUID
    mutating func removeRow(_ id: UUID)
    mutating func setRowText(_ text: String, of id: UUID)
    /// Why the row is not saved; `editing` is the row being typed in.
    func rowProblem(of id: UUID, editing: UUID?) -> Problem?
}

/// One row as the list draws it.
struct EditableRowItem: Identifiable, Equatable {
    let id: UUID
    let text: String
}

/// What a list says: its rows' placeholder and VoiceOver name, its empty
/// state, its ＋ and −, and why a row is not saved.
struct EditableRowListText<Problem> {
    let placeholder: Text
    let rowLabel: LocalizedStringResource
    let empty: EmptyState
    let add: LocalizedStringResource
    let remove: LocalizedStringResource
    let reason: (Problem) -> LocalizedStringResource
}

/// The macOS list-editing form (a bordered list with ＋ and − under it).
/// The rows are one-line fields, so a row is edited where it is read; −
/// removes the row the cursor was last in. A row the draft does not save
/// carries a mark that says why. `trailing` ends the bar under the list.
struct EditableRowList<Draft: EditableRowsDraft, Trailing: View>: View {
    @Binding var draft: Draft
    let text: EditableRowListText<Draft.Problem>
    @ViewBuilder let trailing: () -> Trailing

    /// The row the cursor is in.
    @FocusState private var focusedRow: UUID?
    /// The row − removes: the one the cursor was last in. Kept apart from
    /// the focus, which leaves the field when − itself is pressed.
    @State private var selectedRow: UUID?

    private static var rowHeight: CGFloat {
        22
    }

    var body: some View {
        VStack(spacing: 0) {
            rows
            Divider()
            bar
        }
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .onChange(of: focusedRow) { _, row in
            if let row {
                selectedRow = row
            }
        }
    }

    @ViewBuilder private var rows: some View {
        if draft.rowItems.isEmpty {
            // The message in the one row the list keeps, so the box does
            // not jump as its last row goes (`EditableRowListLayoutTests`).
            SupervisionEmptyState(text.empty, size: .inline)
                .frame(height: Self.rowHeight)
                .padding(.vertical, Self.rowsVerticalInset)
        } else {
            VStack(spacing: 0) {
                ForEach(draft.rowItems) { row in
                    rowView(row)
                }
            }
            .padding(.vertical, Self.rowsVerticalInset)
        }
    }

    /// Above the first row and under the last.
    private static var rowsVerticalInset: CGFloat {
        4
    }

    private func rowView(_ row: EditableRowItem) -> some View {
        let problem = draft.rowProblem(of: row.id, editing: focusedRow)
        let isSelected = selectedRow == row.id
        return HStack(spacing: WeirLayout.Supervision.spaceS) {
            TextField(
                "",
                text: Binding(get: { row.text }, set: { draft.setRowText($0, of: row.id) }),
                prompt: text.placeholder
            )
            .textFieldStyle(.plain)
            // A grouped form lays a field out as a value beside its label,
            // even an empty one: in the trailing column, its words against
            // the trailing edge. Hidden, the label takes no column, so the
            // field spans the row, and a command or a path is read from its
            // start (`EditableRowListLayoutTests`).
            .labelsHidden()
            .font(.system(.body, design: .monospaced))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focusedRow, equals: row.id)
            .accessibilityLabel(Text(text.rowLabel))
            .accessibilityValue(problem.map { Text(text.reason($0)) } ?? Text(verbatim: ""))
            if let problem {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SupervisionTokens.waitingText.color)
                    .help(Text(text.reason(problem)))
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, WeirLayout.Supervision.spaceS)
        .frame(height: Self.rowHeight)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                    .padding(.horizontal, WeirLayout.Supervision.spaceXS)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selectedRow = row.id
            focusedRow = row.id
        }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            Button {
                let row = draft.addRow()
                selectedRow = row
                focusedRow = row
            } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 20)
            }
            .help(Text(text.add))
            .accessibilityLabel(Text(text.add))
            Divider().frame(height: 14)
            Button {
                guard let row = selectedRow else { return }
                removeRow(row)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 24, height: 20)
            }
            .disabled(selectedRow.map { id in !draft.rowItems.contains { $0.id == id } } ?? true)
            .help(Text(text.remove))
            .accessibilityLabel(Text(text.remove))
            Spacer(minLength: 0)
            trailing()
                .padding(.trailing, WeirLayout.Supervision.spaceXS)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, WeirLayout.Supervision.spaceHairline)
        .frame(height: 24)
    }

    /// Removes `row` and moves the selection to its neighbor, as a macOS
    /// list does, so − can be pressed again.
    private func removeRow(_ row: UUID) {
        guard let index = draft.rowItems.firstIndex(where: { $0.id == row }) else { return }
        draft.removeRow(row)
        let items = draft.rowItems
        let next = items.indices.contains(index) ? index : items.index(before: items.endIndex)
        selectedRow = items.indices.contains(next) ? items[next].id : nil
    }
}

extension CheckCommandsDraft: EditableRowsDraft {
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
        problem(of: id, editing: editing, normalizing: CommandLineText.sanitizeSmartPunctuation)
    }
}

/// Project Settings' list of test commands, with Restore Default.
struct TestCommandsList: View {
    @Binding var draft: CheckCommandsDraft

    var body: some View {
        EditableRowList(draft: $draft, text: EditableRowListText(
            placeholder: Text("Command", comment: "Project settings: placeholder of a new test command row"),
            rowLabel: ProjectSettingsText.checkCommands,
            empty: .noTestCommands,
            add: LocalizedStringResource("Add Command", comment: "Project settings: the ＋ under the test command list"),
            remove: LocalizedStringResource("Remove Command", comment: "Project settings: the − under the test command list"),
            reason: Self.reason
        )) {
            if draft.differsFromDefaults(normalizing: CommandLineText.sanitizeSmartPunctuation) {
                RestoreDefaultButton(accessibilityLabel: LocalizedStringResource(
                    "Restore Default Test Commands",
                    comment: "Project settings: VoiceOver name and tooltip of Restore Default under the test command list"
                )) {
                    draft.restoreDefaults()
                }
            }
        }
    }

    static func reason(_ problem: CheckCommandsDraft.Problem) -> LocalizedStringResource {
        switch problem {
        case .empty:
            LocalizedStringResource(
                "An empty row isn’t saved.",
                comment: "Project settings: why a row of a list is not saved"
            )
        case .duplicate:
            LocalizedStringResource(
                "This command is already in the list, so this row isn’t saved.",
                comment: "Project settings: why a test command row is not saved"
            )
        case .misplacedWildcard:
            LocalizedStringResource(
                "A * works only at the end, so this row isn’t saved.",
                comment: "Project settings: why a test command row is not saved"
            )
        }
    }
}
