// ReviewTableFixture.swift
// Limpid — one file's diff table as the review draws it, for the tests of what the table shows and sends.

import SwiftUI
@testable import Limpid

/// The table's settings no table test is about (unified layout, the number
/// width, no search, no syntax language, the macOS default editor) are
/// fixed here, and each test passes the settings it is about. The selection's
/// binding, the composer, and the locale have no defaults that could stand
/// in for them silently, since a live binding keeps what a drag selects and
/// a constant one does not. A test passes the callbacks it observes, and the
/// rest do nothing.
enum ReviewTableFixture {
    /// This is the composer under a line, or none.
    struct Composer {
        var lineID: Int?
        var text: Binding<String>

        /// This means no composer is open.
        static var closed: Self {
            Self(lineID: nil, text: .constant(""))
        }
    }

    /// Makes the table of `file` open with `rows` from row 1 under its header
    /// (`ReviewStackFixture.open`), drawn from `lines`. `key` keys both its
    /// content and its widths.
    @MainActor
    static func table( // swiftlint:disable:this function_parameter_count
        _ file: ReviewFile,
        rows: [ReviewRow],
        lines: [ReviewLine],
        counts: [Int: Int] = [:],
        key: String,
        selection: Binding<ReviewDiffSelection>,
        composer: Composer,
        locale: Locale,
        isInteractionEnabled: Bool = true,
        isOverlayPresented: Bool = false,
        onCompose: @escaping () -> Void = {},
        onOpenLine: @escaping (Int, String?) -> Void = { _, _ in },
        onCloseOverlay: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) -> ReviewDiffTable {
        ReviewDiffTable(
            stack: ReviewStackFixture.open(file, rows: rows, lines: lines, counts: counts),
            diffLines: lines,
            contentKey: key, widthKey: key, layout: .unified,
            files: [file], numberWidth: 26, expandedFileID: file.id,
            isInteractionEnabled: isInteractionEnabled,
            selection: selection,
            composerLineID: composer.lineID, composerStartLine: nil,
            composerIsEditing: false, composerText: composer.text,
            onSelectFile: { _ in }, onCompose: onCompose, onCancelCompose: {}, onCommit: {}, onInsert: {},
            search: ReviewSearch(), onCloseSearch: {}, searchTargetLineID: nil, language: nil,
            onToggleViewed: {}, fileApplication: .macOSDefault, onOpenLine: onOpenLine, onExpand: { _, _ in },
            onResolve: { _ in }, onEdit: { _ in }, onDelete: { _ in },
            isOverlayPresented: isOverlayPresented, onCloseOverlay: onCloseOverlay, onClose: onClose,
            locale: locale
        )
    }
}
