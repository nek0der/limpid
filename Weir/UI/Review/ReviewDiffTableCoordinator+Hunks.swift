// ReviewDiffTableCoordinator+Hunks.swift
// Weir — the review table's hunk headers and what each offers.

import AppKit

extension ReviewDiffTable.Coordinator {
    /// A hunk's header row, drawn for the layout and for the surface under
    /// it.
    func hunkRow(_ tableView: NSTableView, line: ReviewLine, row: Int) -> NSView {
        let view = reuse(tableView, "review-hunk", ReviewHunkRowView.init)
        configure(view, line: line, row: row)
        return view
    }

    func configure(_ view: ReviewHunkRowView, line: ReviewLine, row: Int) {
        view.configure(
            line,
            numberWidth: parent.numberWidth,
            layout: parent.layout,
            surfaceOpacity: parent.surfaceOpacity
        )
        configureActions(of: view, line: line, row: row)
    }

    /// What the hunk's header offers, and the callbacks its buttons run.
    func configureActions(of view: ReviewHunkRowView, line: ReviewLine, row: Int) {
        let action = parent.hunkActions[line.id]
        appliedHunkActions[row] = action
        let fileID = closedFileID(forRow: row)
        view.configureActions(
            action,
            isCommentable: parent.commentableHunks.contains(line.id),
            environment: hostedEnvironment,
            handlers: .init(
                onComment: { [weak self] in self?.parent.onCommentHunk(line, fileID) },
                onDiscard: { [weak self] in self?.parent.onDiscardHunk(line, fileID) },
                onUndo: { [weak self] in self?.parent.onUndoDiscard(line, fileID) }
            )
        )
    }

    /// Configures again the hunk rows whose header offers something
    /// else now (a discard ran, the gate changed). Only the rows the table
    /// holds a view for: this runs on every update, a comment's keystrokes
    /// included, and asking for each of five thousand hunks' views cost as
    /// much as the rest of the update. A row without a view is configured
    /// as it is made (`hunkRow`).
    func refreshHunkActions(in table: NSTableView) {
        if hunkRowsKey != parent.contentKey {
            hunkRowsKey = parent.contentKey
            appliedHunkActions = [:]
        }
        table.enumerateAvailableRowViews { rowView, row in
            guard parent.rows.indices.contains(row),
                  case let .hunk(line) = parent.rows[row].kind,
                  let view = rowView.view(atColumn: 0) as? ReviewHunkRowView,
                  appliedHunkActions[row] != parent.hunkActions[line.id]
            else { return }
            configureActions(of: view, line: line, row: row)
        }
    }
}
