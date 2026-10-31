// CatalogWordingTests.swift
// Weir — the string catalog keeps its wording rules in every entry, including ones added later.

import Foundation
import Testing
@testable import Weir

/// Each rule here was broken somewhere in the catalog once. The checks read
/// every entry, so a new string that breaks one fails here rather than in
/// a screenshot review.
@Suite(.disabled(if: !RepoFixture.hasLocalRepo))
struct CatalogWordingTests {
    /// One entry's shown text: its English (the key when it has none of its
    /// own) and its Japanese, every plural variation included.
    struct Entry {
        let key: String
        let english: [String]
        let japanese: [String]
        /// The translator's note, which says when VoiceOver reads it.
        var comment = ""
    }

    static func entries() throws -> [Entry] {
        let root = try #require(RepoFixture.weirRoot)
        let data = try Data(contentsOf: root.appending(path: "Weir/Resources/Localizable.xcstrings"))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(catalog["strings"] as? [String: Any])
        return strings.map { key, entry in
            let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
            let english = CatalogFixture.values(in: localizations["en"])
            return Entry(
                key: key,
                english: english.isEmpty ? [key] : english,
                japanese: CatalogFixture.values(in: localizations["ja"]),
                comment: (entry as? [String: Any])?["comment"] as? String ?? ""
            )
        }
    }

    /// Japanese never addresses the reader as 「あなた」, which macOS does
    /// not do either, and never leaves an English name that has a
    /// Japanese one on screen: the review is 「レビュー」, the button is
    /// 「強制削除」, and the new worktree's commands are 「セットアップ」.
    @Test func japanese_hasNoYouAndNoUntranslatedNames() throws {
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains("あなた"), "\(entry.key)")
                #expect(!value.contains(#/\bReview\b|\bForce\b|(?i:\bsetup\b|\bbootstrap\b)/#), "\(entry.key): \(value)")
            }
        }
    }

    /// The new worktree's words: 「セットアップ」 for its commands everywhere
    /// (on macOS 「初期化」 means erasing, as in 「Mac を初期化」), a Git fetch
    /// is 「フェッチ」 as Xcode and JetBrains say it (「取得」 is the pull
    /// request's lookup), changes are moved (「移動」), a pull request is
    /// 「PR」, and the files Git ignores are said so; never the spoken
    /// 「持っていく」 or 「最新を取ってくる」, nor 「管理外」. 「初期化」 stays
    /// for what Git and libghostty initialize (「初期化済みのサブモジュール」).
    @Test func japanese_saysTheNewWorktreesWordsPlainly() throws {
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains(#/初期化コマンド|初期化を|^初期化$|プルリクエスト|管理外|移す|移し|移せ/#), "\(entry.key): \(value)")
                if entry.english.contains(where: { $0.contains(#/(?i)\bfetch/#) }) {
                    #expect(!value.contains("取得"), "\(entry.key): \(value)")
                }
                #expect(!value.contains(#/持っていく|持っていけ|持ってこ|最新を取って|取ってこ|すぐ作る/#), "\(entry.key): \(value)")
            }
        }
    }

    /// The window is 「ウインドウ」, as the menus AppKit draws beside ours
    /// say it, and an agent waiting on a person's answer is 「回答待ち」:
    /// 「質問待ち」 read as waiting for a question.
    @Test func japanese_saysWindowAndWaitingForAnswerAsMacOSDoes() throws {
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains(#/ウィンドウ|質問待ち/#), "\(entry.key): \(value)")
            }
        }
    }

    /// A string written for VoiceOver says in words what the screen says
    /// in symbols: a tooltip's " · " is read 「中黒」, "→" 「右矢印」, a
    /// spaced " / " 「スラッシュ」, a count "4/4" as a date, and a key such as
    /// ⌘⏎ letter by letter, burying the name, and "T7" as 「ティー なな」. Its
    /// state is a word (「展開済み」), not the sentence 「展開されています」 it
    /// once was.
    @Test func voiceOverStrings_sayInWordsWhatTheScreenSaysInSymbols() throws {
        let symbols = #/ · |→| / |\d/\d|lld/%|\bT%(\d\$)?lld|[⌘⇧⌥⌃⏎⎋]/#
        for entry in try Self.entries() where entry.comment.contains("VoiceOver") {
            for value in entry.english + entry.japanese {
                #expect(!value.contains(symbols), "\(entry.key): \(value)")
            }
        }
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains(#/展開されています|折りたたまれています/#), "\(entry.key): \(value)")
            }
        }
    }

    /// A worktree is 「ワークツリー」; 「作業ツリー」 is Git's working tree,
    /// which a code restore puts back. Each word is said only for its own
    /// thing, in both languages at once.
    @Test func workingTree_andWorktree_areToldApart() throws {
        for entry in try Self.entries() {
            let saysWorkingTree = entry.english.contains { $0.contains("working tree") }
            let saysSagyouTree = entry.japanese.contains { $0.contains("作業ツリー") }
            #expect(saysWorkingTree == saysSagyouTree, "\(entry.key)")
        }
    }

    /// The English uses US spelling, and no description stops at a symbol
    /// where a sentence belongs ("Empty = no checks."). The new worktree's
    /// commands are "Setup" everywhere, never "bootstrap".
    @Test func english_isUSSpelledSentencesThatSaySetup() throws {
        for entry in try Self.entries() {
            for value in entry.english {
                #expect(!value.contains(#/(?i)recognis|colour|behaviour|initialis|normalis/#), "\(entry.key)")
                #expect(!value.contains("Empty ="), "\(entry.key)")
                #expect(!value.contains(#/(?i)\bbootstrap/#), "\(entry.key)")
            }
            #expect(!entry.japanese.contains { $0.contains("Empty =") }, "\(entry.key)")
        }
    }

    /// One word for each idea, as macOS says it: 「デフォルト」, not 「既定」
    /// or 「初期値」; 「フォルダ」, not 「ディレクトリ」; and an agent is
    /// 「実行中」 (Running), never 「動作中」 or 「稼働」. VoiceOver labels
    /// are entries too, so they say what the screen says.
    @Test func japanese_saysDefaultFolderAndRunning() throws {
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains(#/既定|初期値|初期状態|ディレクトリ|動作中|稼働|動いて|動き続け/#), "\(entry.key): \(value)")
            }
            #expect(!entry.english.contains { $0.contains(#/(?i)\bagents? (is |are )?active\b|\bactive agents?\b/#) }, "\(entry.key)")
        }
    }

    /// The punctuation is one set: ’ and “…” in English, one ellipsis
    /// character, modifiers in Apple's order (⌃⌥⇧⌘), and in Japanese the
    /// full-width ？（）： with 「もう一度お試しください。」 as the one way to
    /// ask for another try.
    @Test func thePunctuation_isOneSet() throws {
        for entry in try Self.entries() {
            for value in entry.english.map(Self.prose) {
                #expect(!value.contains("'") && !value.contains("\""), "\(entry.key)")
            }
            for value in entry.english + entry.japanese {
                #expect(!value.contains("..."), "\(entry.key)")
                #expect(!value.contains(#/⌘[⌃⌥⇧]|⇧[⌃⌥]|⌥⌃/#), "\(entry.key)")
            }
            for value in entry.japanese.map(Self.prose) {
                #expect(!value.contains(#/[?():]/#), "\(entry.key): \(value)")
                #expect(!value.contains(#/もう一度試して|やり直して/#), "\(entry.key): \(value)")
            }
        }
    }

    /// The rest of the fixed words: changes 「ターン外」, Git's conflict
    /// 「競合」, 「このバージョン」, the software's 「アップデート」, a kept
    /// file 「バックアップ」, moving 「移動」, and 「ペースト」 for the
    /// mechanism under the review's 「挿入」. The rails are icon bars, not
    /// JetBrains' tool window bars.
    @Test func theRemainingWords_areOneEach() throws {
        for entry in try Self.entries() {
            for value in entry.japanese {
                #expect(!value.contains(#/ターン以外|貼り付け|コンフリクト|この版|写し|ジャンプ|ソフトウェア・|自動更新/#), "\(entry.key): \(value)")
            }
            #expect(!entry.english.contains { $0.contains("Tool Window") }, "\(entry.key)")
        }
    }

    /// The text the punctuation rules read: a code span, a URL, and a time
    /// keep the ASCII ' " ? ( ) : they are written with outside the app.
    static func prose(_ value: String) -> String {
        value
            .replacing(#/`[^`]*`/#, with: "")
            .replacing(#/[a-z][a-z0-9+.-]*:\/\/\S+/#, with: "")
            .replacing(#/\b\d{1,2}:\d{2}(:\d{2})?\b/#, with: "")
    }
}

/// The checks that read the built catalog rather than the checkout, so they
/// run without one.
struct CatalogWordingBundleTests {
    /// The Settings window's switches, whose labels end in 「〜する」:
    /// a switch turns something on, so its label says what it does.
    static let switches = [
        "Show in menu bar", "Notify when a usage limit resets", "Automatically check for updates",
        "Translucent window", "Ligatures", "Blink", "Use Ghostty config file",
        "Run agents in tmux", "Hide when focus leaves", "Open Review when jumping to an unread turn"
    ]

    @Test(arguments: switches)
    func aSwitch_endsInSuru(key: String) {
        let japanese = LocalizedStringResource(String.LocalizationValue(key)).resolved(in: Locale(identifier: "ja"))
        // A plain verb also says what the switch does (「隠す」, 「開く」).
        let endings = ["する", "させる", "隠す", "開く"]
        #expect(endings.contains { japanese.hasSuffix($0) }, "\(key): \(japanese)")
    }

    /// The punctuation rules spare what is written outside the app.
    @Test func thePunctuationRules_spareCodeURLsAndTimes() {
        let text = "Run `echo 'a: b'` at 10:30 from https://example.com/x?y=(1) now"
        #expect(CatalogWordingTests.prose(text) == "Run  at  from  now")
    }
}
