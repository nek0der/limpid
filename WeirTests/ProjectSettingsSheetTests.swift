// ProjectSettingsSheetTests.swift
// Weir — the project settings sheet fits its window, and Esc in its command editors closes it.

import AppKit
import SwiftUI
import Testing
@testable import Weir

@MainActor
struct ProjectSettingsSheetTests {
    /// The preferred height in a tall window, and before the first
    /// geometry pass (a height of 0) rather than nothing; in a shorter one
    /// the window's margin left, down to the least.
    @Test(arguments: [
        (900.0, WeirLayout.Supervision.projectSettingsSheetPreferredHeight),
        (0, WeirLayout.Supervision.projectSettingsSheetPreferredHeight),
        (500, 500 - WeirLayout.Supervision.sheetWindowMargin),
        (380, WeirLayout.Supervision.projectSettingsSheetMinHeight)
    ] as [(CGFloat, CGFloat)])
    func height_fitsTheWindow(windowHeight: CGFloat, expected: CGFloat) {
        #expect(ContainerSettingsSheet.height(forWindowHeight: windowHeight) == expected)
    }

    @Test func isComposing_noWindow_isFalse() {
        #expect(!ContainerSettingsSheet.isComposing(in: nil))
    }

    @Test func editorEsc_withOnCancel_callsIt_andTakesTheCommand() {
        var cancels = 0
        let coordinator = PlainTextEditor.Coordinator(text: .constant(""), onCancel: { cancels += 1 })
        let handled = coordinator.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(handled)
        #expect(cancels == 1)
    }

    /// The other editors keep the text view's own Esc.
    @Test func editorEsc_withoutOnCancel_isLeftToTheTextView() {
        let coordinator = PlainTextEditor.Coordinator(text: .constant(""))
        #expect(!coordinator.textView(NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    }

    @Test func editorOtherCommands_areLeftToTheTextView() {
        var cancels = 0
        let coordinator = PlainTextEditor.Coordinator(text: .constant(""), onCancel: { cancels += 1 })
        #expect(!coordinator.textView(NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(cancels == 0)
    }
}
