// LiveLocaleAppKitTests.swift
// Limpid — the AppKit parts of the app take their words from the locale
// they are handed, and pick up a language switch while on screen.
//
// AppKit text is outside SwiftUI's environment, so each view here resolves
// in an explicit locale: menus when they are built, pooled rows when they
// are configured, hosted fields and the review table when SwiftUI updates
// them, the quick terminal panel when the app locale changes.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@Suite("Live display language in AppKit")
@MainActor
struct LiveLocaleAppKitTests {
    private let en = Locale(identifier: "en")
    private let ja = Locale(identifier: "ja")

    // MARK: - Menus and pooled rows

    @Test func terminalContextMenu_titlesFollowTheLocale() {
        let state = SurfaceContextMenuState(
            hasSelection: true,
            isInPane: true,
            canRenamePane: true,
            zoomAction: .zoom,
            canMoveToNewTab: true,
            shortcut: { _ in nil }
        )
        let japanese = SurfaceContextMenu.make(state, locale: ja).items.filter { !$0.isSeparatorItem }.map(\.title)
        let english = SurfaceContextMenu.make(state, locale: en).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(english == [
            "Copy", "Paste", "Select All", "Clear", "Scroll to Top", "Scroll to Bottom", "Find…", "Rename Pane…",
            "Split Right", "Split Down", "Zoom Pane", "Move Pane to New Tab", "Close Pane"
        ])
        #expect(japanese.count == english.count)
        #expect(japanese.first == "コピー")
        #expect(japanese.last == "ペインを閉じる")
        #expect(zip(japanese, english).allSatisfy { $0 != $1 })
    }

    @Test func terminalContextMenu_outsideAPaneOffersOnlyTheTerminalItems() {
        let state = SurfaceContextMenuState(
            hasSelection: false,
            isInPane: false,
            canRenamePane: false,
            zoomAction: nil,
            canMoveToNewTab: false,
            shortcut: { _ in nil }
        )
        let titles = SurfaceContextMenu.make(state, locale: en).items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Paste", "Select All", "Clear", "Scroll to Top", "Scroll to Bottom"])
    }

    @Test func reviewCommentRow_takesItsWordsFromTheLocaleItIsConfiguredWith() {
        let comment = ReviewComment(
            file: ReviewFile(path: "a.swift", layer: .untracked, status: .added),
            fingerprint: "snapshot",
            anchor: ReviewAnchor(lineID: 1, oldLine: nil, newLine: 2),
            code: "+x",
            codeMarkers: "+",
            body: "Fix this."
        )
        let metrics = ReviewCardMetrics(viewport: 600, numberWidth: 26, layout: .unified)
        let row = ReviewCommentRowView()
        row.configure(comment, metrics: metrics, locale: ja)
        #expect(buttonTitles(in: row) == ["解決済みにする", "編集", "削除"])
        #expect(labels(in: row).contains("コメント"))
        #expect(labels(in: row).contains { $0.hasPrefix("未追跡") })

        // The same pooled row, reused after a switch back to English.
        row.configure(comment, metrics: metrics, locale: en)
        #expect(buttonTitles(in: row) == ["Resolve", "Edit", "Delete"])
        #expect(labels(in: row).contains { $0.hasPrefix("Untracked") })
    }

    @Test func reviewNoticeRow_followsTheLocale() {
        let notice = ReviewNoticeRowView()
        notice.configure("This file cannot be reviewed as text.", locale: ja)
        let english = LocalizedStringResource("This file cannot be reviewed as text.").resolved(in: en)
        #expect(labels(in: notice) == [LocalizedStringResource("This file cannot be reviewed as text.").resolved(in: ja)])
        #expect(labels(in: notice) != [english])
    }

    @Test func reviewExpanderRow_reconfiguresInTheNewLocale() {
        let expander = ReviewExpander(
            gap: 0, beforeLineID: 4, hidden: 12, canExpandUp: true, canExpandDown: true, canCollapse: false
        )
        let row = ReviewExpanderRowView()
        row.configure(expander, numberWidth: 26, layout: .unified, locale: en)
        #expect(toolTips(in: row).contains("Expand Up"))
        #expect(labels(in: row).contains("12 hidden lines"))

        row.configure(expander, numberWidth: 26, layout: .unified, locale: ja)
        #expect(toolTips(in: row).contains("上に展開"))
        #expect(!labels(in: row).contains("12 hidden lines"))
        #expect(labels(in: row).contains(LocalizedStringResource("\(12) hidden lines").resolved(in: ja)))
    }

    @Test func reviewComposer_reconfiguresInTheNewLocale() {
        let line = ReviewLine(id: 0, kind: .added, text: "new", oldLine: nil, newLine: 1)
        let metrics = ReviewCardMetrics(viewport: 600, numberWidth: 26, layout: .unified)
        let composer = ReviewComposerRowView()
        composer.configure(line, start: nil, text: "", isEditing: false, metrics: metrics, locale: en)
        #expect(labels(in: composer).contains("Leave a comment"))
        #expect(buttonTitles(in: composer) == ["Cancel", "Add"])

        composer.configure(line, start: nil, text: "", isEditing: true, metrics: metrics, locale: ja)
        #expect(labels(in: composer).contains("コメントを入力"))
        #expect(buttonTitles(in: composer) == ["キャンセル", LocalizedStringResource("Save").resolved(in: ja)])
        #expect(!labels(in: composer).contains("Leave a comment"))
    }

    // MARK: - Hosted views updated by SwiftUI

    @Test func reviewTable_reloadsItsRowsWhenTheLocaleChanges() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: makeTable(locale: ja))
        window.contentView = host
        await settle(host)
        let table = try #require(descendants(of: host).compactMap { $0 as? ReviewTableView }.first)
        #expect(table.menuLocale == ja)
        #expect(commentButtonTitles(in: host) == ["解決済みにする", "編集", "削除"])

        host.rootView = makeTable(locale: en)
        await settle(host)
        #expect(table.menuLocale == en)
        #expect(commentButtonTitles(in: host) == ["Resolve", "Edit", "Delete"])
    }

    @Test func reviewFindField_placeholderFollowsTheLocale() async throws {
        let host = NSHostingView(rootView: Localized(locale: ja) {
            ReviewFindField(text: .constant(""), onMove: { _ in }, onCancel: {}, focusRequest: 0)
        })
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        await settle(host)
        let field = try #require(descendants(of: host).compactMap { $0 as? NSTextField }.first)
        #expect(field.placeholderString == "ファイル内を検索")

        host.rootView = Localized(locale: en) {
            ReviewFindField(text: .constant(""), onMove: { _ in }, onCancel: {}, focusRequest: 0)
        }
        await settle(host)
        #expect(field.placeholderString == "Find in file")
    }

    @Test func paneSearchField_placeholderFollowsTheLocale() async throws {
        let field = { PaneSearchTextField(
            text: .constant(""), isFocused: .constant(false), onChange: { _ in }, onSubmit: { _ in }, onExit: {}
        ) }
        let host = NSHostingView(rootView: Localized(locale: ja, content: field))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
        await settle(host)
        let textField = try #require(descendants(of: host).compactMap { $0 as? PaneSearchNSTextField }.first)
        #expect(textField.placeholderString == "検索")
        #expect(textField.accessibilityLabel() == "検索")

        host.rootView = Localized(locale: en, content: field)
        await settle(host)
        #expect(textField.placeholderString == "Search")
    }

    @Test func quickTerminalPanel_titleFollowsTheAppLocale() async throws {
        // Never created: the test changes no setting, so the store has no
        // reason to write `settings.json` there.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = try #require(InMemoryDefaults())
        let store = SettingsStore(directory: directory, languageSources: AppLanguageSources(
            defaults: defaults,
            systemPreferredLanguages: { ["en-US"] },
            currentLocale: { Locale(identifier: "en_US") }
        ))
        let controller = QuickTerminalController(
            settingsStore: store,
            reduceTransparencyResolver: ReduceTransparencyResolver(),
            clipboard: ClipboardConfirmationCoordinator(),
            secureInputManager: SecureInputManager(),
            surfaceFactory: { nil }
        )
        #expect(controller.panel.title == "Quick Terminal")

        store.appLanguage = .japanese
        for _ in 0..<50 where controller.panel.title == "Quick Terminal" {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.panel.title == "クイックターミナル")
        #expect(controller.panel.accessibilityTitle() == "クイックターミナル")
    }

    // MARK: - Helpers

    /// Lets SwiftUI run its update and AppKit lay out the rows it asked for.
    private func settle(_ host: NSView) async {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func commentButtonTitles(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? ReviewCommentRowView }.first.map(buttonTitles(in:)) ?? []
    }

    private func makeTable(locale: Locale) -> ReviewDiffTable {
        let file = ReviewFile(path: "a.swift", layer: .unstaged, status: .modified)
        let line = ReviewLine(id: 0, kind: .added, text: "new", oldLine: nil, newLine: 1)
        let comment = ReviewComment(
            file: file, fingerprint: "f", anchor: ReviewAnchor(lineID: 0, oldLine: nil, newLine: 1),
            code: "+new", codeMarkers: "+", body: "Fix this."
        )
        return ReviewDiffTable(
            rows: [ReviewRow(id: 0, kind: .code(line)), ReviewRow(id: 1, kind: .comment(comment))],
            diffLines: [line], intralineHighlights: ReviewIntralineHighlights(),
            contentKey: "locale", widthKey: "locale", layout: .unified,
            files: [file], lineCommentCounts: [0: 1], numberWidth: 26, expandedFileID: file.id, contentIdentity: file.id,
            isInteractionEnabled: true,
            selection: .constant(ReviewDiffSelection()),
            composerLineID: nil, composerStartLine: nil,
            composerIsEditing: false, composerText: .constant(""),
            onSelectFile: { _ in }, onCompose: {}, onCancelCompose: {}, onCommit: {}, onInsert: {}, onToggleTerminal: {},
            search: ReviewSearch(), onCloseSearch: {}, searchTargetLineID: nil, language: nil,
            onToggleViewed: {}, fileApplication: .macOSDefault, onOpenLine: { _ in }, onExpand: { _, _ in },
            onResolve: { _ in }, onEdit: { _ in }, onDelete: { _ in },
            isOverlayPresented: false, onCloseOverlay: {}, onClose: {},
            locale: locale
        )
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func buttonTitles(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? NSButton }.map(\.title).filter { !$0.isEmpty }
    }

    private func toolTips(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? NSButton }.compactMap(\.toolTip)
    }

    private func labels(in view: NSView) -> [String] {
        descendants(of: view).compactMap { $0 as? NSTextField }.map(\.stringValue).filter { !$0.isEmpty }
    }
}

/// Hosts `content` under an explicit `\.locale`, with one stable type so a
/// test can swap the locale by replacing the root view.
private struct Localized<Content: View>: View {
    let locale: Locale
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.locale, locale)
    }
}
