// EmptyStateTests.swift
// Weir — every empty state's words follow one rule in both languages, and what VoiceOver reads of each.

import AppKit
import SwiftUI
import Testing
@testable import Weir

/// The inventory (`EmptyState.inventory`) is every empty state the app
/// draws, so each rule here holds for every list, panel, and popover.
@MainActor
struct EmptyStateTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    /// The words English leaves in lower case inside a title.
    private static let minorWords: Set = ["a", "an", "the", "in", "of", "to", "for", "on", "at", "by", "and", "or"]

    // MARK: - Words

    /// Each message says what is absent, in title case in English, and in
    /// Japanese as written, not as the English key: no "yet" and no
    /// 「まだ」, which promise a list that may never fill, and no full stop.
    @Test(arguments: EmptyState.inventory)
    func eachMessage_saysWhatIsAbsent_inBothLanguages(state: EmptyState) {
        let english = state.message(locale: Self.english)
        let japanese = state.message(locale: Self.japanese)

        #expect(!english.isEmpty && !japanese.isEmpty)
        #expect(english != japanese, "\(english) has a Japanese translation")
        #expect(!english.localizedCaseInsensitiveContains("yet"), "\(english)")
        #expect(!japanese.contains("まだ"), "\(japanese)")
        #expect(!japanese.hasSuffix("。"), "\(japanese)")
        #expect(!english.hasSuffix("."), "\(english)")
        let words = english.split(separator: " ")
        for (index, word) in words.enumerated() where index == 0 || !Self.minorWords.contains(String(word)) {
            #expect(word.first?.isUppercase == true, "\(english): \(word)")
        }
    }

    /// The inventory holds every kind of empty state: `kindNumber` names
    /// each case, so a new one does not compile until it has a number
    /// there, and the inventory must then hold one of it.
    @Test func theInventory_holdsEveryKind() {
        #expect(Set(EmptyState.inventory.map(\.kindNumber)) == Set(0...23))
    }

    /// Where its surface sizes itself to what it holds (a popover, All
    /// Projects), each size still has a height of its own, the compact one
    /// the shorter.
    @Test func eachSize_hasAHeightOfItsOwn_whereItsSurfaceFitsIt() {
        let regular = fittingHeight(of: SupervisionEmptyState(.noNotifications, size: .regular).frame(width: 320))
        let compact = fittingHeight(of: SupervisionEmptyState(.noNotifications, size: .compact).frame(width: 320))
        #expect(compact > 0)
        #expect(compact < regular)
        #expect(regular < 300, "\(regular): no taller than its words")
    }

    /// A description, when there is one, is a sentence in both languages,
    /// except the Settings search's aside, which repeats what was typed.
    @Test(arguments: EmptyState.inventory)
    func eachDescription_isASentence_inBothLanguages(state: EmptyState) {
        guard case .noSettingsFound = state else {
            let english = state.description(locale: Self.english)
            let japanese = state.description(locale: Self.japanese)
            #expect((english == nil) == (japanese == nil), "both languages describe it, or neither")
            if let english, let japanese {
                #expect(english.hasSuffix("."), "\(english)")
                #expect(japanese.hasSuffix("。"), "\(japanese)")
                #expect(english != japanese)
            }
            return
        }
        #expect(state.description(locale: Self.english) == "font")
    }

    /// The surfaces whose words say the same absence share one message.
    @Test func theSameAbsence_saysTheSameWords() {
        #expect(EmptyState.noTabs.message(locale: Self.japanese) == "タブはありません")
        #expect(EmptyState.noOpenTab(newTabShortcut: "⌘T").message(locale: Self.japanese) == "タブはありません")
        #expect(EmptyState.noWorktreeSelected.message(locale: Self.english) == "No Worktree Selected")
        #expect(EmptyState.noWorktreeSelected.message(locale: Self.japanese) == "ワークツリーが選択されていません")
        #expect(EmptyState.nothingNeedsAttention.message(locale: Self.japanese) == "要対応はありません")
        #expect(EmptyState.noNotifications.message(locale: Self.japanese) == "通知はありません")
    }

    /// All Projects lists only the worktrees with a tab open or an item,
    /// so with no card it says none is open, not that there is none.
    @Test func allProjectsWithNoCard_saysNoWorktreeIsOpen_notThatThereIsNone() {
        #expect(EmptyState.noOpenWorktrees.message(locale: Self.english) == "No Open Worktrees")
        #expect(EmptyState.noOpenWorktrees.message(locale: Self.japanese) == "開いているワークツリーはありません")
        #expect(EmptyState.noOpenWorktrees.description(locale: Self.english)
            == "Worktrees with a tab open or something that needs attention appear here.")
        #expect(EmptyState.noOpenWorktrees.description(locale: Self.japanese) == "タブを開いているワークツリーと、\n要対応のあるワークツリーが表示されます。")
        #expect(EmptyState.noOpenWorktrees.message(locale: Self.english) != EmptyState.noWorktreeSelected.message(locale: Self.english))
    }

    /// With no project at all, the sidebar and All Projects say so rather
    /// than that a worktree is absent or closed; the Open Folder… button
    /// under it says how one is added, so there is no description.
    @Test func noProject_saysThereIsNone_withNoDescription() {
        #expect(EmptyState.noProjects.message(locale: Self.english) == "No Projects")
        #expect(EmptyState.noProjects.message(locale: Self.japanese) == "プロジェクトはありません")
        #expect(EmptyState.noProjects.description(locale: Self.english) == nil)
        #expect(EmptyState.noProjects.symbol == "folder")
    }

    /// Each symbol is one the system has, so no empty state draws a blank
    /// where its symbol would be.
    @Test(arguments: EmptyState.inventory)
    func eachSymbol_isASystemSymbol(state: EmptyState) {
        #expect(NSImage(systemSymbolName: state.symbol, accessibilityDescription: nil) != nil, "\(state.symbol)")
    }

    // MARK: - VoiceOver

    /// VoiceOver reads the message, then the description, as two
    /// sentences of one element; with no description, the message alone.
    @Test func theSpokenWords_areTheMessageThenTheDescription() {
        #expect(EmptyState.noNotifications.spoken(locale: Self.english)
            == "No Notifications. Agent responses and completed commands appear here.")
        #expect(EmptyState.noNotifications.spoken(locale: Self.japanese)
            == "通知はありません。エージェントの応答とコマンドの完了が表示されます。")
        #expect(EmptyState.noResults.spoken(locale: Self.english) == "No Results")
        #expect(EmptyState.noResults.spoken(locale: Self.japanese) == "結果はありません")
    }

    // MARK: - Sizes

    /// All Projects sizes itself to what it holds, so its empty state
    /// brings a room of its own, taller than its words, rather than sitting
    /// tight under the header; no taller than that room while the words
    /// fit in it.
    @Test func allProjectsEmptyState_takesARoomOfItsOwn() {
        let room = fittingHeight(of: AllProjectsEmptyState(state: .noOpenWorktrees).frame(width: 600))
        let words = fittingHeight(of: SupervisionEmptyState(.noOpenWorktrees, size: .regular).frame(width: 600))
        #expect(words < WeirLayout.Supervision.allProjectsEmptyMinHeight)
        #expect(room == WeirLayout.Supervision.allProjectsEmptyMinHeight)
    }

    /// The session area with no tab draws its commands and nothing over
    /// them: five rows are five times one row's height, with no symbol or
    /// title on top.
    @Test func theEmptySessionArea_drawsOnlyItsCommands_withNoTitle() {
        func hints(_ count: Int) -> EmptySessionHints {
            EmptySessionHints(
                message: EmptyState.noTabs.message(locale: Self.english),
                hints: Array(repeating: EmptySessionHints.Hint(title: "New Tab", keys: "⌘T", isEnabled: true, run: {}), count: count)
            )
        }
        let insets = 2 * WeirLayout.Supervision.spaceL
        let row = fittingHeight(of: hints(1)) - insets
        let five = fittingHeight(of: hints(5)) - insets

        #expect(row > 0)
        #expect(abs(five - 5 * row) < 1, "\(five) for five rows of \(row)")
        #expect(row < 30, "\(row): a compact row")
    }

    /// In a popover, the room under the words is more than the room over
    /// the symbol (the heading line's slack around its words, the heading's
    /// bottom inset, the block's top inset), by a step, and clears the
    /// popover's rounded corner, which makes the same room read as less.
    @Test func aPopoversEmptyState_hasMoreRoomUnderItsWordsThanOverItsSymbol() {
        let compact = SupervisionEmptyState<EmptyView>.Metrics(.compact)
        let headingWords = fittingHeight(of: Text(verbatim: "Needs Attention").font(.supervision(.row)))
        let above = (WeirLayout.Supervision.secondaryButtonHeight - headingWords) / 2
            + WeirLayout.Supervision.needsAttentionHeadingBottomInset
            + compact.insets.top
        let below = compact.insets.bottom

        #expect(below > WeirLayout.floatingPanelCornerRadius)
        #expect(below - above >= WeirLayout.Supervision.spaceXS, "\(above) over the symbol, \(below) under the words")
    }

    /// In a panel, the block sits a little above the middle of its room,
    /// and keeps the height it had at the middle.
    @Test func aPanelsEmptyState_sitsALittleAboveTheMiddle() {
        let regular = SupervisionEmptyState<EmptyView>.Metrics(.regular)
        #expect(regular.insets.bottom > regular.insets.top)
        #expect(regular.insets.top + regular.insets.bottom == 2 * WeirLayout.Supervision.spaceL)
    }

    /// A description that wraps is set in lines of even length: in
    /// Japanese, the incomplete record's description leaves no word or two
    /// alone on its second line, and its two lines take about the same
    /// width.
    @Test func aWrappedDescription_isSetInLinesOfEvenLength() {
        let japanese = Self.japanese
        let description = EmptyState.incompleteRecord.description(locale: japanese) ?? ""
        let text = Text(verbatim: description).font(.system(size: WeirFont.Supervision.Size.meta.rawValue))
        let room: CGFloat = 280
        let plain = NSHostingView(rootView: text.frame(width: room)).fittingSize
        let balanced = NSHostingView(rootView: BalancedLines { text }.frame(width: room)).fittingSize
        // Offered the room, it reports the width its lines take.
        let balancedWidth = NSHostingView(rootView: WidthCap(max: room) { BalancedLines { text } }).fittingSize.width
        let single = NSHostingView(rootView: text.fixedSize()).fittingSize.width

        #expect(single > room, "\(single): the description wraps at \(room)")
        #expect(abs(balanced.height - plain.height) < 1, "as many lines as the room gives")
        #expect(balancedWidth < room - 20, "\(balancedWidth): narrower than the room")
        #expect(balancedWidth >= single / 2, "\(balancedWidth): no narrower than half the line")
    }

    /// A list's box in a form draws the message alone: no symbol and no
    /// description.
    @Test func theInlineSize_isTheMessageAlone() {
        let inline = fittingHeight(of: SupervisionEmptyState(.noTestCommands, size: .inline).frame(width: 400))
        let compact = fittingHeight(of: SupervisionEmptyState(.noTestCommands, size: .compact).frame(width: 400))
        #expect(inline > 0)
        #expect(inline < 22, "\(inline): one line of words")
        #expect(inline < compact)
    }

    /// A popover's empty state is smaller than a panel's at every step.
    @Test func theCompactSize_isSmallerThanTheRegular() {
        let regular = SupervisionEmptyState<EmptyView>.Metrics(.regular)
        let compact = SupervisionEmptyState<EmptyView>.Metrics(.compact)
        #expect(compact.symbol.rawValue < regular.symbol.rawValue)
        #expect(compact.message.rawValue < regular.message.rawValue)
        #expect(compact.description.rawValue < regular.description.rawValue)
        #expect(compact.symbolGap < regular.symbolGap)
        #expect(compact.descriptionGap < regular.descriptionGap)
        #expect(regular.description.rawValue < regular.message.rawValue, "the description is under the message")
    }
}

private extension EmptyState {
    /// One number per case, from a switch that names every one.
    var kindNumber: Int {
        switch self {
        case .noWorktreeSelected: 0
        case .noMatchingWorktrees: 1
        case .nothingNeedsAttention: 2
        case .noNotifications: 3
        case .noAgentNotifications: 4
        case .noCommandNotifications: 5
        case .noUnreadNotifications: 6
        case .noTurns: 7
        case .notGitRepository: 8
        case .changesUnavailable: 9
        case .noChangesInScope: 10
        case .incompleteRecord: 11
        case .noComments: 12
        case .noMatchingFiles: 13
        case .noResults: 14
        case .noMatchingShortcuts: 15
        case .noSettingsFound: 16
        case .noTestCommands: 17
        case .noFilesToCopy: 18
        case .noTabs: 19
        case .noOpenTab: 20
        case .scratchElsewhere: 21
        case .noOpenWorktrees: 22
        case .noProjects: 23
        }
    }
}
