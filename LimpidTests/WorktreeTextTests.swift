// WorktreeTextTests.swift
// Limpid — a sidebar row is a worktree in English and Japanese, never a workspace, a session, a task, or a section.

import Foundation
import Testing
@testable import Limpid

struct WorktreeTextTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    @Test func theRailEntry_namesTheRowsWorktrees() {
        #expect(WorktreeText.railEntry.resolved(in: Self.english) == "Worktrees")
        #expect(WorktreeText.railEntry.resolved(in: Self.japanese) == "ワークツリー")
    }

    /// The File menu, the palette, and the keyboard settings read the
    /// action's title, and a tooltip names it with its default key.
    /// There is one action for it, which ⌘N runs.
    @Test func theCreateAction_isNewWorktree_onCommandN_inTheMenuAndTheTooltip() throws {
        let title = LimpidShortcutAction.newWorktree.localizedTitle
        #expect(title.resolved(in: Self.english) == "New Worktree…")
        #expect(title.resolved(in: Self.japanese) == "新規ワークツリー…")

        let key = try #require(KeyboardSettings().shortcut(for: .newWorktree)?.displayString)
        #expect(key == "⌘N")
        #expect(ShortcutHelpText.make(name: title, shortcut: key, locale: Self.english) == "New Worktree… (⌘N)")
        #expect(ShortcutHelpText.make(name: title, shortcut: key, locale: Self.japanese) == "新規ワークツリー…（⌘N）")
    }

    /// The sheet's title says it in the words of the project header's ＋.
    @Test func theSheetTitle_namesTheProject_asTheHeadersPlusDoes() {
        let title = WorktreeText.sheetTitle(project: "limpid")
        #expect(title.resolved(in: Self.english) == "New Worktree in limpid")
        #expect(title.resolved(in: Self.japanese) == "limpid に新規ワークツリー")
        #expect(SidebarHeaderText.newWorktree(in: "limpid").resolved(in: Self.japanese) == "limpid に新規ワークツリー…")
    }

    /// The menu items and the empty lists name the row the same way. These
    /// are the literals the views pass, resolved against the catalog.
    @Test func theMenusAndEmptyLists_nameTheRowAWorktree() {
        #expect(LocalizedStringResource("Go to Worktree \(2)").resolved(in: Self.english) == "Go to Worktree 2")
        #expect(LocalizedStringResource("Go to Worktree \(2)").resolved(in: Self.japanese) == "ワークツリー 2 へ移動")
        #expect(LocalizedStringResource("Next Worktree").resolved(in: Self.japanese) == "次のワークツリー")
        #expect(LocalizedStringResource("Previous Worktree").resolved(in: Self.japanese) == "前のワークツリー")
        // The row's menu entry closes the tabs and keeps the row.
        #expect(LocalizedStringResource("Close All Tabs").resolved(in: Self.japanese) == "すべてのタブを閉じる")
        #expect(EmptyState.noWorktreeSelected.message(locale: Self.japanese) == "ワークツリーが選択されていません")
        #expect(EmptyState.noMatchingWorktrees.message(locale: Self.japanese) == "一致するワークツリーはありません")
        #expect(LocalizedStringResource("Worktree name").resolved(in: Self.japanese) == "ワークツリーの名前")
    }

    /// An empty pane area names the row a worktree and New Tab's key as
    /// the keymap has it now, not a fixed ⌘T.
    @Test func theEmptyPane_namesTheWorktree_andTodaysNewTabKey() throws {
        let key = try #require(KeyboardSettings().shortcut(for: .newTab)?.displayString)
        #expect(WorktreeText.emptyPaneDetail(newTabShortcut: key).resolved(in: Self.english)
            == "Choose a worktree in the sidebar, or open a new tab with \(key).")
        #expect(WorktreeText.emptyPaneDetail(newTabShortcut: "⌃F5").resolved(in: Self.japanese)
            == "サイドバーでワークツリーを選択するか、⌃F5 で新しいタブを開いてください。")
        #expect(WorktreeText.emptyPaneDetail(newTabShortcut: nil).resolved(in: Self.english)
            == "Choose a worktree in the sidebar, or open a new tab.")
        #expect(WorktreeText.emptyPaneDetail(newTabShortcut: nil).resolved(in: Self.japanese)
            == "サイドバーでワークツリーを選択するか、新しいタブを開いてください。")
    }

    /// The keyboard settings, the palette, and the ⌘/ sheet read the
    /// actions' titles: ⌘[ ⌘] walk the worktrees, and ⌥⌘R is the menu's
    /// "Review".
    @Test func theShortcutTitles_nameTheWorktrees_andTheReview() {
        #expect(LimpidShortcutAction.nextSession.localizedTitle.resolved(in: Self.english) == "Next Worktree")
        #expect(LimpidShortcutAction.nextSession.localizedTitle.resolved(in: Self.japanese) == "次のワークツリー")
        #expect(LimpidShortcutAction.previousSession.localizedTitle.resolved(in: Self.english) == "Previous Worktree")
        #expect(LimpidShortcutAction.previousSession.localizedTitle.resolved(in: Self.japanese) == "前のワークツリー")
        #expect(LimpidShortcutAction.review.localizedTitle.resolved(in: Self.english) == "Review")
        #expect(LimpidShortcutAction.review.localizedTitle.resolved(in: Self.japanese) == "レビュー")
    }

    /// The Keyboard pane's caption names what ⌃⌘1–9 is kept for, in
    /// sentences, and calls the decision bar by what the person sees.
    @Test func theKeyboardCaption_reservesTheNumberKeysForTabAndWorktreeJumps() {
        // The key is the pane's literal, whole: split across lines it would
        // name another entry.
        let caption = LocalizedStringResource(
            // swiftlint:disable:next line_length
            "Click a shortcut to change it. Press ⎋ to cancel, or ⌫ to restore the default. To leave one unassigned, choose Unassign from its ⋯ menu. ⌘⏎ is kept for the main button under an agent’s pane, and ⌘1–9 and ⌃⌘1–9 for moving between tabs and worktrees."
        )
        #expect(caption.resolved(in: Self.english).hasSuffix("for moving between tabs and worktrees."))
        let japanese = caption.resolved(in: Self.japanese)
        #expect(japanese.hasPrefix("ショートカットをクリックすると、割り当てを変更できます。"))
        #expect(japanese.hasSuffix("タブとワークツリーの移動に使うため、割り当てられません。"))
        #expect(!japanese.contains("決定バー"))
    }

    /// The strings that may say "session" (セッション): window restore and
    /// tmux, where the word means what it always has. A new string that
    /// says it has to be added here on purpose, which is the moment to ask
    /// whether it names a row.
    private static let sessionAllowlist: Set<String> = [
        "Previous Session Repaired",
        "Couldn’t Restore the Previous Session",
        "Previous Session Not Restored",
        "Saved session uses schema v%lld; Limpid expected v%lld. A fresh window was opened instead.",
        "Your sessions aren’t being saved: state.json can’t be read by this version and couldn’t be set aside. "
            + "Move it out of the folder, then quit and reopen Limpid.",
        "Running in tmux — the session survives quitting Limpid",
        "Starts each agent in a tmux session of its own. The agent keeps running when Limpid quits, including "
            + "the relaunch after an update, and the pane reconnects to the same session on the next launch. "
            + "Requires tmux.\n\nApplies to panes opened after the change. The pane’s scrollback stays in tmux "
            + "rather than Limpid. A command that prints and exits, such as `claude --version`, runs outside it."
    ]

    /// What is wrong with a catalog entry's words, if anything: "session"
    /// outside the allowlist, or "task", "section", or "workspace" anywhere,
    /// which never names a row: a row is a worktree. "Section" was the
    /// old window's word for the sidebar's groups and projects, which the
    /// window has none of now; no string the app shows uses it for anything
    /// else.
    private static func oldRowWords(key: String, english: [String], japanese: [String]) -> [String] {
        var problems: [String] = []
        let saysSession = english.contains { $0.contains(#/(?i)\bsessions?\b/#) }
            || japanese.contains { $0.contains("セッション") }
        if saysSession, !sessionAllowlist.contains(key) {
            problems.append("says session")
        }
        if english.contains(where: { $0.contains(#/(?i)\btasks?\b/#) }) || japanese.contains(where: { $0.contains("タスク") }) {
            problems.append("says task")
        }
        if english.contains(where: { $0.contains(#/(?i)\bsections?\b/#) }) || japanese.contains(where: { $0.contains("セクション") }) {
            problems.append("says section")
        }
        if english.contains(where: { $0.contains(#/(?i)\bworkspaces?\b/#) }) || japanese.contains(where: { $0.contains("ワークスペース") }) {
            problems.append("says workspace")
        }
        return problems
    }

    /// No string the app shows names a row by its old words, including a
    /// string added after this test.
    @Test(.disabled(if: !RepoFixture.hasLocalRepo))
    func noShownString_callsARowAWorkspaceASessionATaskOrASection() throws {
        let root = try #require(RepoFixture.limpidRoot)
        let data = try Data(contentsOf: root.appending(path: "Limpid/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        var allowedSeen: Set<String> = []
        for (key, entry) in strings {
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            // An entry with no English of its own shows its key.
            let english = CatalogFixture.values(in: localizations["en"])
            let problems = Self.oldRowWords(
                key: key,
                english: english.isEmpty ? [key] : english,
                japanese: CatalogFixture.values(in: localizations["ja"])
            )
            #expect(problems.isEmpty, "\(key): \(problems)")
            if Self.sessionAllowlist.contains(key) {
                allowedSeen.insert(key)
            }
        }
        // An allowlisted string that is gone leaves a hole a new one could
        // slip through under the same key.
        #expect(allowedSeen == Self.sessionAllowlist)
    }

    /// The rows' old names, in either language, fail the check if they
    /// come back.
    @Test(arguments: [
        ("Close Session", "セッションを閉じる"),
        ("Next Session", "次のセッション"),
        ("Previous Session", "前のセッション"),
        ("Go to Session %lld", "セッション %lld へ移動"),
        ("No sessions yet", "まだセッションがありません"),
        ("Tabs & Sessions", "タブとセッション"),
        ("%lld sessions", "%lld 個のタブ"),
        ("New Session…", "新規セッション…"),
        ("Tasks", "タスク"),
        ("Next Section", "次のセクション"),
        ("Previous Section", "前のセクション"),
        ("Go to Section %lld", "セクション %lld へ移動"),
        ("Tabs & Sections", "タブとセクション"),
        ("New Workspace…", "新規ワークスペース…"),
        ("Go to Workspace %lld", "ワークスペース %lld へ移動"),
        ("No workspaces yet", "まだワークスペースがありません")
    ])
    func theReplacedWords_failTheCheck(english: String, japanese: String) {
        #expect(!Self.oldRowWords(key: english, english: [english], japanese: [japanese]).isEmpty)
        // Either language alone is enough.
        #expect(!Self.oldRowWords(key: english, english: [english], japanese: []).isEmpty)
        if ["セッション", "タスク", "セクション", "ワークスペース"].contains(where: japanese.contains) {
            #expect(!Self.oldRowWords(key: english, english: [], japanese: [japanese]).isEmpty)
        }
    }
}
