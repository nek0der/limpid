// ReceiptFormattingTests.swift
// Limpid — a turn's receipt in words, in English and Japanese.

import Foundation
import Testing
@testable import Limpid

@Suite("Receipt formatting")
struct ReceiptFormattingTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")

    private static func turn(_ numbers: ClosedRange<Int>?, _ changes: ChangeSummary, check: CheckSummary? = nil) -> UnreadTurn {
        UnreadTurn(turnID: TurnID("t"), numbers: numbers, changes: changes, check: check, conversation: TurnSummaryFixture.conversation)
    }

    @Test func aTurnThatChangedFiles_saysItsNumber_whatItChanged_andItsCheck() {
        let check = CheckSummary(command: "make test FILTER=x", isFiltered: true, exitCode: 0)
        let turn = Self.turn(7...7, .changed(files: 2, added: 94, removed: 2), check: check)

        #expect(ReceiptText.receipt(turn, locale: Self.english) == "T7 · 2 files +94 −2 · ✓ Tests (filtered)")
        #expect(ReceiptText.receipt(turn, locale: Self.japanese) == "T7 · 2 ファイル +94 −2 · ✓ テスト（絞り込み）")
    }

    @Test func oneFile_isSingular_andARunOfTurns_namesItsEnds() {
        let turn = Self.turn(6...7, .changed(files: 1, added: 3, removed: 0))

        #expect(ReceiptText.receipt(turn, locale: Self.english) == "T6–T7 · 1 file +3 −0")
        #expect(ReceiptText.receipt(turn, locale: Self.japanese) == "T6〜T7 · 1 ファイル +3 −0")
    }

    @Test func answerOnly_isSaidOnlyWhenTheComparisonFoundNothing() {
        #expect(ReceiptText.receipt(Self.turn(3...3, .unchanged), locale: Self.english) == "T3 · No file changes")
        #expect(ReceiptText.receipt(Self.turn(3...3, .unchanged), locale: Self.japanese) == "T3 · ファイルの変更なし")
        // Not taken, or of a kind this build cannot read: never "No file changes".
        #expect(ReceiptText
            .receipt(Self.turn(5...5, .unavailable(reason: "notGit")), locale: Self.english) == "T5 · Couldn’t get the changes")
        #expect(ReceiptText.receipt(Self.turn(5...5, .unavailable(reason: "notGit")), locale: Self.japanese) == "T5 · 変更を取得できませんでした")
        #expect(ReceiptText.changes(.unknown, locale: Self.japanese) == "このバージョンでは読み取れない変更")
        #expect(ReceiptText.changes(.pending, locale: Self.japanese) == "変更を取得中…")
    }

    @Test func aCheckIsMarked_onlyWhenItsExitCodeIsItsOwn() {
        func check(_ exitCode: Int?, isFiltered: Bool = false) -> CheckSummary {
            CheckSummary(command: "cargo test", isFiltered: isFiltered, exitCode: exitCode)
        }

        #expect(ReceiptText.check(check(0), locale: Self.english) == "✓ Tests")
        #expect(ReceiptText.check(check(101), locale: Self.english) == "✗ Tests")
        #expect(ReceiptText.check(check(nil), locale: Self.english) == "Tests", "piped on, or in the background")
        #expect(ReceiptText.check(check(1, isFiltered: true), locale: Self.japanese) == "✗ テスト（絞り込み）")
    }

    /// A check after failures of the turn says so, the decision bar and
    /// notifications included, since the turn had trouble getting there.
    @Test func aCheckAfterFailures_saysHowMany() {
        func check(_ exitCode: Int?, isFiltered: Bool = false, failures: Int) -> CheckSummary {
            CheckSummary(command: "cargo test", isFiltered: isFiltered, exitCode: exitCode, earlierFailures: failures)
        }

        #expect(ReceiptText.check(check(0, failures: 1), locale: Self.english) == "✓ Tests (after 1 failure)")
        #expect(ReceiptText.check(check(0, failures: 2), locale: Self.english) == "✓ Tests (after 2 failures)")
        #expect(ReceiptText.check(check(0, isFiltered: true, failures: 2), locale: Self.japanese) == "✓ テスト（絞り込み、失敗 2 回）")
        #expect(ReceiptText.check(check(nil, failures: 2), locale: Self.english) == "Tests (after 2 failures)")
        // A failure is one of the failures it counts.
        #expect(ReceiptText.check(check(1, failures: 0), locale: Self.english) == "✗ Tests")
        #expect(ReceiptText.check(check(1, failures: 1), locale: Self.english) == "✗ Tests (2 failures)")
        #expect(ReceiptText.check(check(1, isFiltered: true, failures: 3), locale: Self.english) == "✗ Tests (filtered, 4 failures)")
        #expect(ReceiptText.check(check(1, failures: 2), locale: Self.japanese) == "✗ テスト（失敗 3 回）")
        #expect(ReceiptText.check(check(0, failures: 0), locale: Self.japanese) == "✓ テスト", "nothing to say without one")
    }

    @Test func theBarsRuns_setTheCountsAndAFailedCheckApart_andReadAsTheReceipt() {
        let check = CheckSummary(command: "make test", isFiltered: false, exitCode: 1)
        let turn = Self.turn(7...7, .changed(files: 2, added: 94, removed: 2), check: check)

        let unread = ReceiptText.runs(turn, includesTurnNumber: false, emphasizesChanges: true, locale: Self.japanese)
        #expect(unread == [
            ReceiptRun(text: "2 ファイル ", role: .emphasized),
            ReceiptRun(text: "+94", role: .added(isEmphasized: true)),
            ReceiptRun(text: " ", role: .emphasized),
            ReceiptRun(text: "−2", role: .removed(isEmphasized: true)),
            ReceiptRun(text: " · ", role: .quiet),
            ReceiptRun(text: "✗ テスト", role: .failed)
        ])

        // At rest the number leads, nothing is set apart, and the runs read
        // as the receipt's one sentence.
        let atRest = ReceiptText.runs(turn, includesTurnNumber: true, emphasizesChanges: false, locale: Self.english)
        #expect(atRest.map(\.text).joined() == ReceiptText.receipt(turn, locale: Self.english))
        #expect(atRest.first == ReceiptRun(text: "T7", role: .plain))
        #expect(atRest.contains(ReceiptRun(text: "+94", role: .added(isEmphasized: false))))
    }

    @Test func aPassingCheck_andChangesWithNoCounts_areOneRunEach() {
        let check = CheckSummary(command: "make test", isFiltered: false, exitCode: 0)
        let runs = ReceiptText.runs(
            Self.turn(3...3, .unchanged, check: check),
            includesTurnNumber: false,
            emphasizesChanges: true,
            locale: Self.english
        )
        #expect(runs == [
            ReceiptRun(text: "No file changes", role: .emphasized),
            ReceiptRun(text: " · ", role: .quiet),
            ReceiptRun(text: "✓ Tests", role: .plain)
        ])
    }

    @Test(arguments: ["en", "ja", "de"])
    func largeCounts_keepTheirColors_howeverTheLocaleGroupsThem(_ identifier: String) throws {
        let locale = Locale(identifier: identifier)
        let summary = ChangeSummary.changed(files: 3, added: 12345, removed: 6789)
        let runs = ReceiptText.changeRuns(summary, isEmphasized: true, locale: locale)

        // The runs are the sentence, cut where the counts are.
        #expect(runs.map(\.text).joined() == ReceiptText.changes(summary, locale: locale))
        let added = try #require(runs.first { $0.role == .added(isEmphasized: true) })
        let removed = try #require(runs.first { $0.role == .removed(isEmphasized: true) })
        #expect(added.text.hasPrefix("+") && added.text.filter(\.isNumber) == "12345", "\(identifier): \(added.text)")
        #expect(removed.text.hasPrefix("−") && removed.text.filter(\.isNumber) == "6789", "\(identifier): \(removed.text)")
    }

    @Test func changesWithNoCountsToFind_areOneRun() {
        #expect(ReceiptText.changeRuns(.unavailable(reason: "notGit"), isEmphasized: false, locale: Self.japanese)
            == [ReceiptRun(text: "変更を取得できませんでした", role: .plain)])
        #expect(ReceiptText.changeRuns(.pending, isEmphasized: true, locale: Self.english)
            == [ReceiptRun(text: "Getting the changes…", role: .emphasized)])
    }

    @Test func onlyACheckThatExitedNonZero_hasFailed() {
        #expect(CheckSummary(command: "make test", isFiltered: false, exitCode: 2).hasFailed)
        #expect(!CheckSummary(command: "make test", isFiltered: false, exitCode: 0).hasFailed)
        #expect(!CheckSummary(command: "make test | tail", isFiltered: false, exitCode: nil).hasFailed, "not the check's own status")
    }

    @Test func anEpisodeNoRecordStandsFor_hasNoNumber() {
        let episode = UnreadTurn(turnID: TurnID("r#1"), changes: .unknown)

        #expect(ReceiptText.receipt(episode, locale: Self.english) == "Changes this version can’t read")
    }
}
