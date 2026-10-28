// NotificationHistoryRowTextTests.swift
// Limpid — a notification history row's two lines, its glyph, where it came from, and how an older entry is read.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct NotificationHistoryRowTextTests {
    private let ja = Locale(identifier: "ja")
    private let en = Locale(identifier: "en")

    private func entry(
        kind: NotificationEntry.Kind = .agentNeedsInput,
        paneID: UUID? = nil,
        tabTitleSnapshot: String? = nil,
        containerLabel: String? = nil,
        containerID: ContainerID? = nil,
        title: String = "Claude",
        body: String = "Waiting for your input",
        exitCode: Int? = nil,
        durationSeconds: Double? = nil,
        isRead: Bool = false,
        requestKey: ApprovalKey? = nil,
        event: NotificationEvent? = nil
    ) -> NotificationEntry {
        NotificationEntry.test(
            kind: kind,
            paneID: paneID,
            tabTitleSnapshot: tabTitleSnapshot,
            containerLabel: containerLabel,
            containerID: containerID,
            title: title,
            body: body,
            exitCode: exitCode,
            durationSeconds: durationSeconds,
            isRead: isRead,
            requestKey: requestKey,
            event: event
        )
    }

    private func lines(_ entry: NotificationEntry, tab: String? = nil, locale: Locale) -> NotificationHistoryRowText.Lines {
        NotificationHistoryRowText.lines(of: entry, sourceTabTitle: tab, locale: locale)
    }

    // MARK: - Place

    @Test func anOpenPane_isPlacedByItsProject() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let tab = session.openTab(container: .project(project.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let place = NotificationHistoryRowText.place(of: entry(paneID: paneID), in: session, locale: ja)
        #expect(place == .init(name: "limpid", projectID: project.id))
    }

    @Test func aPaneOutsideAnyProject_isScratch() {
        let (session, _, paneID) = WorkspaceSessionFixture.withLooseTab()
        let place = NotificationHistoryRowText.place(of: entry(paneID: paneID), in: session, locale: ja)
        #expect(place == .init(name: "スクラッチ", projectID: nil))
    }

    @Test func aWorktreesPane_isPlacedByItsProjectAndWorktree() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let worktree = try #require(session.attachGitWorktree(
            projectID: project.id,
            label: "feat-x",
            workingDirectory: URL(fileURLWithPath: "/tmp/limpid-feat-x"),
            branchName: "feat-x"
        ))
        let tab = session.openTab(container: .worktree(projectID: project.id, worktreeID: worktree.id))
        let paneID = try #require(tab.splitTree.allLeafIDs().first)
        let place = NotificationHistoryRowText.place(of: entry(paneID: paneID), in: session, locale: ja)
        #expect(place == .init(name: "limpid / feat-x", projectID: project.id))
    }

    @Test func aClosedScratchPane_isScratch_notTheRecordedQuickTabs() {
        let session = WorkspaceSession()
        let gone = entry(paneID: UUID(), containerLabel: "クイックタブ", containerID: .loose)
        #expect(NotificationHistoryRowText.place(of: gone, in: session, locale: ja) == .init(name: "スクラッチ", projectID: nil))
    }

    @Test func aClosedPane_inAProjectStillOpen_isPlacedByIt() {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let gone = entry(paneID: UUID(), containerLabel: "old name", containerID: .project(project.id))
        #expect(NotificationHistoryRowText.place(of: gone, in: session, locale: ja) == .init(name: "limpid", projectID: project.id))
    }

    @Test func aClosedPane_fallsBackToTheRecordedContainer_orNothing() {
        let session = WorkspaceSession()
        #expect(NotificationHistoryRowText.place(of: entry(paneID: UUID(), containerLabel: "app / main"), in: session, locale: ja)
            == .init(name: "app / main", projectID: nil))
        #expect(NotificationHistoryRowText.place(of: entry(paneID: nil), in: session, locale: ja) == nil)
    }

    @Test func aPlaceInAnotherWindow_isOnlyAProjectAnotherWindowShows() {
        let other = UUID()
        #expect(NotificationHistoryRowText.isInAnotherWindow(.init(name: "api", projectID: other), projectsInOtherWindows: [other]))
        #expect(!NotificationHistoryRowText.isInAnotherWindow(.init(name: "web", projectID: UUID()), projectsInOtherWindows: [other]))
        #expect(!NotificationHistoryRowText.isInAnotherWindow(.init(name: "Scratch", projectID: nil), projectsInOtherWindows: [other]))
    }

    // MARK: - What happened, from the event

    @Test func aWait_saysWhichFirst_andWhatItNamesUnder() {
        let approval = entry(event: .wait(agent: .claude, wait: .approval, fact: "limpid-u07-b.txt"))
        #expect(lines(approval, locale: ja) == .init(
            headline: "承認待ち",
            facts: [],
            detail: "limpid-u07-b.txt",
            isDetailASubject: true,
            reply: nil
        ))
        #expect(lines(approval, locale: en).headline == "Needs approval")
        let question = entry(event: .wait(agent: .claude, wait: .question, fact: "Which color?"))
        #expect(lines(question, locale: ja).headline == "回答待ち")
        #expect(lines(question, locale: ja).detail == "Which color?")
        #expect(!lines(question, locale: ja).isDetailASubject)
        let response = entry(event: .wait(agent: .codex, wait: .response, fact: "  "))
        #expect(lines(response, locale: ja) == .init(headline: "応答待ち", facts: [], detail: nil, isDetailASubject: false, reply: nil))
    }

    @Test func aFinishedTurn_leadsWithItsReceipt_andAZeroCountIsQuiet() throws {
        let turn = try TurnSummaryFixture.turn("T4", changes: #"{"kind":"changed","files":2,"added":94,"removed":0}"#, number: 4)
        let finished = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: turn, head: "Unify the login errors"))
        let row = lines(finished, locale: ja)
        #expect(row.headline == "ターンが完了しました")
        #expect(row.firstLine == "ターンが完了しました · T4 · 2 ファイル +94 −0")
        #expect(row.detail == "Unify the login errors")
        #expect(row.facts.contains(ReceiptRun(text: "+94", role: .added(isEmphasized: false))))
        #expect(row.facts.contains(ReceiptRun(text: "−0", role: .quiet)))
        // No record: the headline alone, the prompt under it.
        let bare = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: nil, head: "Add the tests"))
        #expect(lines(bare, locale: en) == .init(
            headline: "Turn finished",
            facts: [],
            detail: "Add the tests",
            isDetailASubject: false,
            reply: nil
        ))
    }

    @Test func aTurnTheHarnessPrompted_isWordedByItsKind() throws {
        let turn = try TurnSummaryFixture.turn("T7", number: 7, extras: .init(promptKind: .backgroundTask))
        let finished = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: turn, head: nil))
        let row = lines(finished, locale: ja)
        #expect(row.firstLine == "ターンが完了しました · T7 · ファイルの変更なし")
        #expect(row.detail == TurnPromptText.instruction(TurnPrompt(kind: .backgroundTask, head: nil), locale: ja))
    }

    @Test func aStop_saysWhy_under() {
        let stop = entry(kind: .agentError, event: .stopped(agent: .claude, reason: "5-hour limit reached"))
        #expect(lines(stop, locale: ja) == .init(
            headline: "停止",
            facts: [],
            detail: "5-hour limit reached",
            isDetailASubject: false,
            reply: nil
        ))
    }

    // MARK: - Commands and alerts

    @Test func aCommand_namesItsTab_onlyWhenTheHeadingNamesAnother() {
        let finished = entry(kind: .commandFinished, tabTitleSnapshot: "zsh", title: "zsh", body: "", exitCode: 0, durationSeconds: 48)
        let duration = DurationText.command(48, locale: ja)
        #expect(lines(finished, tab: "zsh", locale: ja) == .init(
            headline: "コマンドが完了しました",
            facts: [],
            detail: duration,
            isDetailASubject: false,
            reply: nil
        ))
        #expect(lines(finished, tab: "server", locale: ja).detail == "zsh · \(duration)")
        let failed = entry(kind: .commandFinished, tabTitleSnapshot: "zsh", body: "", exitCode: 1, durationSeconds: 134)
        let row = lines(failed, tab: "zsh", locale: ja)
        #expect(row.firstLine == "コマンドが失敗しました · 終了コード 1")
        #expect(lines(failed, tab: "zsh", locale: en).firstLine == "Command failed · exit 1")
    }

    @Test func anAlert_isItsTitle_thenItsBody_onOneLine() {
        let alert = entry(kind: .desktop, title: "Build", body: "Done.\nNext step")
        #expect(lines(alert, locale: en) == .init(
            headline: "Build",
            facts: [],
            detail: "Done. Next step",
            isDetailASubject: false,
            reply: nil
        ))
        let untitled = entry(kind: .desktop, title: " ", body: "完了しました。\n次へ")
        #expect(lines(untitled, locale: ja) == .init(headline: "完了しました。次へ", facts: [], detail: nil, isDetailASubject: false, reply: nil))
    }

    // MARK: - Glyph

    @Test func theGlyph_isAmberOrRed_onlyWhileTheAgentStillWaits() {
        let wait = entry(event: .wait(agent: .claude, wait: .approval, fact: nil))
        let happening = NotificationHistoryRowText.happening(of: wait, locale: en)
        func mark(_ entry: NotificationEntry, _ live: NotificationLiveStatus?, closed: Bool = false) -> NotificationHistoryRowText.Mark {
            NotificationHistoryRowText.mark(
                of: entry,
                happening: NotificationHistoryRowText.happening(of: entry, locale: en),
                liveStatus: live,
                isSourceClosed: closed
            )
        }
        #expect(NotificationHistoryRowText
            .mark(of: wait, happening: happening, liveStatus: .stillWaiting, isSourceClosed: false) == .approval)
        #expect(mark(wait, .resolved) == .idle)
        #expect(mark(wait, .stillWaiting, closed: true) == .idle)
        let stop = entry(kind: .agentError, event: .stopped(agent: .claude, reason: nil))
        #expect(mark(stop, .stillWaiting) == .stopped)
        // Nothing live to ask: colored while unread, resting once read.
        #expect(mark(entry(event: .wait(agent: .claude, wait: .question, fact: nil)), nil) == .question)
        #expect(mark(entry(isRead: true, event: .wait(agent: .claude, wait: .question, fact: nil)), nil) == .idle)
        let failed = entry(kind: .commandFinished, body: "", exitCode: 2)
        #expect(mark(failed, nil) == .stopped)
        #expect(mark(entry(kind: .commandFinished, body: "", exitCode: 2, isRead: true), nil) == .idle)
        #expect(mark(entry(kind: .commandFinished, body: "", exitCode: 0), nil) == .idle)
        #expect(mark(entry(kind: .agentFinished, event: .finished(agent: .claude, turn: nil, head: nil)), nil) == .idle)
    }

    @Test func voiceOver_readsWhatHappened_itsDetail_when_andUnread() {
        let row = lines(entry(event: .wait(agent: .claude, wait: .approval, fact: "notes.txt")), locale: ja)
        #expect(NotificationHistoryRowText.spokenLabel(row, timeLabel: "たった今", isUnread: true, locale: ja)
            == "承認待ち、notes.txt、たった今、未読")
        // A receipt kept as text is read as a list, its turn in words.
        let turn = NotificationHistoryRowText.Lines(
            headline: "Turn finished",
            facts: [ReceiptRun(text: " · ", role: .quiet), ReceiptRun(text: "T7 · 2 files +3 −1", role: .plain)],
            detail: "zsh · 3s",
            isDetailASubject: false,
            reply: nil
        )
        #expect(NotificationHistoryRowText.spokenLabel(turn, timeLabel: "now", isUnread: false, locale: Locale(identifier: "en"))
            == "Turn finished, Turn 7, 2 files +3 −1, zsh, 3s, now")
        // A reply is said as one, after the prompt.
        let replied = NotificationHistoryRowText.Lines(
            headline: "Turn finished",
            facts: [],
            detail: "Add the tests",
            isDetailASubject: false,
            reply: "Added two tests."
        )
        #expect(NotificationHistoryRowText.spokenLabel(replied, timeLabel: "now", isUnread: false, locale: Locale(identifier: "en"))
            == "Turn finished, Add the tests, Reply: Added two tests., now")
    }

    // MARK: - Entries from before events

    @Test(arguments: [
        ("Waiting for approval: notes.txt", NotificationEvent.Wait.approval, "notes.txt"),
        ("承認待ち：notes.txt", .approval, "notes.txt"),
        ("Question: Which color?", .question, "Which color?"),
        ("質問：どの色にしますか？", .question, "どの色にしますか？"),
        ("Needs response: Continue?", .response, "Continue?"),
        ("応答待ち：続けますか？", .response, "続けますか？"),
        ("Bash: swift test", .approval, "swift test")
    ])
    func anOlderWait_isReadFromItsWords_inEitherLanguage(_ body: String, _ wait: NotificationEvent.Wait, _ fact: String) {
        #expect(NotificationHistoryRowText.happening(of: entry(body: body), locale: ja) == .wait(wait, fact: fact))
    }

    @Test func anOlderWait_withNothingNamed_isReadFromItsTitle() {
        for (body, wait) in [
            ("Claude Code is waiting for approval", NotificationEvent.Wait.approval),
            ("Codex が質問しています", .question),
            ("Needs answer", .question),
            ("承認待ち", .approval)
        ] {
            #expect(NotificationHistoryRowText.happening(of: entry(body: body), locale: en) == .wait(wait, fact: nil))
        }
        // Words that are none of these: a wait for a response.
        #expect(NotificationHistoryRowText.happening(of: entry(body: "Waiting for your input"), locale: en)
            == .wait(.response, fact: "Waiting for your input"))
        // A held request's body that is not an approval is its question.
        let key = ApprovalKey(epoch: UUID(), runID: UUID(), requestID: UUID())
        #expect(NotificationHistoryRowText.happening(of: entry(body: "Which color?", requestKey: key), locale: en)
            == .wait(.question, fact: "Which color?"))
    }

    @Test func anOlderTurn_isItsReceipt_thenItsInstruction() {
        func turn(_ body: String) -> NotificationHistoryRowText.Happening {
            NotificationHistoryRowText.happening(of: entry(kind: .agentFinished, body: body), locale: en)
        }
        #expect(turn("T7 · 2 files +3 −1\nAdd the tests")
            == .turn(receipt: [ReceiptRun(text: "T7 · 2 files +3 −1", role: .plain)], instruction: "Add the tests", reply: nil))
        #expect(turn("T2 · 回答のみ") == .turn(receipt: [ReceiptRun(text: "T2 · 回答のみ", role: .plain)], instruction: nil, reply: nil))
        #expect(turn("Add the tests") == .turn(receipt: [], instruction: "Add the tests", reply: nil))
        #expect(turn("Claude Code finished a turn") == .turn(receipt: [], instruction: nil, reply: nil))
        // A harness's prompt, quoted with its tags before events: no line.
        #expect(turn("T3 · Answer only\n<task-notification> <task-id>b1</task-id>")
            == .turn(receipt: [ReceiptRun(text: "T3 · Answer only", role: .plain)], instruction: nil, reply: nil))
    }

    @Test func anOlderStop_isItsReason_unlessItOnlyNamedTheAgent() {
        #expect(NotificationHistoryRowText.happening(of: entry(kind: .agentError, body: "Claude Code が停止しました"), locale: ja)
            == .stopped(reason: nil))
        #expect(NotificationHistoryRowText.happening(of: entry(kind: .agentError, body: "Rate limited"), locale: ja)
            == .stopped(reason: "Rate limited"))
    }

    // MARK: - Decoding the event

    private func decoded(event: String) throws -> NotificationEntry {
        let json = """
        {"id":"\(UUID().uuidString)","kind":"agentNeedsInput","timestamp":"2026-10-18T00:00:00Z",\
        "title":"t","body":"Waiting for approval: notes.txt","isRead":false,"event":\(event)}
        """
        return try PersistenceCoders.makeDecoder().decode(NotificationEntry.self, from: Data(json.utf8))
    }

    @Test(arguments: [
        #"{"type":"hologram","agent":"claude"}"#,
        #"{"type":"wait","agent":"gemini","wait":"approval"}"#,
        #"{"type":"wait","agent":"claude","wait":"permission"}"#,
        #"{"type":"turnFinished","agent":"claude","promptKind":"dream"}"#,
        #"{"type":"turnFinished","agent":"claude","promptKind":"text","turn":{"number":"four"}}"#,
        #"{"type":"wait","agent":"claude","wait":"approval","fact":42}"#,
        #""a sentence""#
    ])
    func anEventThisBuildCannotRead_costsTheEvent_notTheEntry(_ event: String) throws {
        let entry = try decoded(event: event)
        #expect(entry.event == nil)
        #expect(entry.body == "Waiting for approval: notes.txt")
        // The row reads its recorded words instead.
        #expect(NotificationHistoryRowText.happening(of: entry, locale: en) == .wait(.approval, fact: "notes.txt"))
    }

    /// The time a row shows is counted from the `now` it is given, which the
    /// history's timeline moves on every minute while it is open.
    @Test func aRowsTime_movesWithNow() {
        let row = entry()
        let came = row.timestamp
        #expect(NotificationHistoryRowText.timeLabel(for: row, now: came.addingTimeInterval(10), locale: en) == "now")
        #expect(NotificationHistoryRowText.timeLabel(for: row, now: came.addingTimeInterval(5 * 60), locale: en) == "5 min. ago")
        #expect(NotificationHistoryRowText.timeLabel(for: row, now: came.addingTimeInterval(5 * 60), locale: ja) == "5 分前")
    }
}
