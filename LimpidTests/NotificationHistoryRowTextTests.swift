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

    @Test func aWait_namesWhatItAsksAbout_thenWhich() {
        let approval = entry(event: .wait(agent: .claude, wait: .approval, fact: "limpid-u07-b.txt"))
        #expect(lines(approval, locale: ja) == .init(
            headline: "承認待ち",
            subject: "limpid-u07-b.txt",
            isSubjectAName: true,
            outcome: .headline,
            facts: []
        ))
        #expect(lines(approval, locale: en).headline == "Needs approval")
        let question = entry(event: .wait(agent: .claude, wait: .question, fact: "Which color?"))
        #expect(lines(question, locale: ja).subject == "Which color?")
        #expect(!lines(question, locale: ja).isSubjectAName)
        // Nothing named: the wait's name alone.
        let response = entry(event: .wait(agent: .codex, wait: .response, fact: "  "))
        #expect(lines(response, locale: ja) == .init(headline: "応答待ち", subject: "応答待ち", isSubjectAName: false, outcome: nil, facts: []))
    }

    @Test func aFinishedTurn_leadsWithItsInstruction_andEndsWithItsCounts() throws {
        let turn = try TurnSummaryFixture.turn("T4", changes: #"{"kind":"changed","files":2,"added":94,"removed":0}"#, number: 4)
        let finished = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: turn, head: "Unify the login errors"))
        let row = lines(finished, locale: ja)
        #expect(row.headline == "ターンが完了しました")
        #expect(row.subject == "Unify the login errors")
        #expect(row.outcome == .headline)
        // The files counted are the Changes panel's; a zero count is quiet.
        #expect(row.factsText == "T4 +94 −0")
        #expect(row.facts.contains(ReceiptRun(text: "+94", role: .added(isEmphasized: false))))
        #expect(row.facts.contains(ReceiptRun(text: "−0", role: .quiet)))
        // No record: the prompt, and the headline under it.
        let bare = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: nil, head: "Add the tests"))
        #expect(lines(bare, locale: en) == .init(
            headline: "Turn finished",
            subject: "Add the tests",
            isSubjectAName: false,
            outcome: .headline,
            facts: []
        ))
    }

    @Test func aFinishedTurnsReply_isWhatCameOfIt() {
        let replied = NotificationHistoryRowText.lines(
            of: .turn(receipt: [], instruction: "Add the tests", reply: "Added two tests."),
            sourceTabTitle: nil,
            locale: en
        )
        #expect(replied.subject == "Add the tests")
        #expect(replied.outcome == .reply("Added two tests."))
        // No instruction: the headline names the turn, the reply under it.
        let unprompted = NotificationHistoryRowText.lines(
            of: .turn(receipt: [], instruction: nil, reply: "Done."),
            sourceTabTitle: nil,
            locale: en
        )
        #expect(unprompted.subject == "Turn finished")
        #expect(unprompted.outcome == .reply("Done."))
    }

    @Test func aTurnWithNoChanges_endsWithItsNumberAlone() throws {
        let turn = try TurnSummaryFixture.turn("T7", number: 7, extras: .init(promptKind: .backgroundTask))
        let finished = entry(kind: .agentFinished, event: .finished(agent: .claude, turn: turn, head: nil))
        let row = lines(finished, locale: ja)
        #expect(row.factsText == "T7")
        #expect(row.subject == TurnPromptText.instruction(TurnPrompt(kind: .backgroundTask, head: nil), locale: ja))
    }

    @Test func aStop_saysWhy_thenThatItStopped() {
        let stop = entry(kind: .agentError, event: .stopped(agent: .claude, reason: "5-hour limit reached"))
        #expect(lines(stop, locale: ja) == .init(
            headline: "停止",
            subject: "5-hour limit reached",
            isSubjectAName: false,
            outcome: .headline,
            facts: []
        ))
    }

    // MARK: - Commands and alerts

    @Test func aCommand_namesItsTab_onlyWhenTheHeadingNamesAnother() {
        let finished = entry(kind: .commandFinished, tabTitleSnapshot: "zsh", title: "zsh", body: "", exitCode: 0, durationSeconds: 48)
        let duration = DurationText.command(48, locale: ja)
        #expect(lines(finished, tab: "zsh", locale: ja) == .init(
            headline: "コマンドが完了しました",
            subject: "コマンドが完了しました",
            isSubjectAName: false,
            outcome: nil,
            facts: [ReceiptRun(text: duration, role: .plain)]
        ))
        let elsewhere = lines(finished, tab: "server", locale: ja)
        #expect(elsewhere.subject == "zsh")
        #expect(elsewhere.outcome == .headline)
        let failed = entry(kind: .commandFinished, tabTitleSnapshot: "zsh", body: "", exitCode: 1, durationSeconds: 134)
        #expect(lines(failed, tab: "zsh", locale: ja).subject == "コマンドが失敗しました")
        #expect(lines(failed, tab: "zsh", locale: ja).factsText == "終了コード 1 \(DurationText.command(134, locale: ja))")
        #expect(lines(failed, tab: "zsh", locale: en).facts.first == ReceiptRun(text: "exit 1", role: .failed))
    }

    @Test func anAlert_isItsTitle_thenItsBody_onOneLine() {
        let alert = entry(kind: .desktop, title: "Build", body: "Done.\nNext step")
        #expect(lines(alert, locale: en) == .init(
            headline: "Build",
            subject: "Build",
            isSubjectAName: false,
            outcome: .detail("Done. Next step"),
            facts: []
        ))
        let untitled = entry(kind: .desktop, title: " ", body: "完了しました。\n次へ")
        #expect(lines(untitled, locale: ja)
            == .init(headline: "完了しました。次へ", subject: "完了しました。次へ", isSubjectAName: false, outcome: nil, facts: []))
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

    @Test func voiceOver_readsWhatItIsAbout_whatCameOfIt_when_andUnread() {
        let row = lines(entry(event: .wait(agent: .claude, wait: .approval, fact: "notes.txt")), locale: ja)
        #expect(NotificationHistoryRowText.spokenLabel(row, timeLabel: "たった今", isUnread: true, locale: ja)
            == "notes.txt、承認待ち、たった今、未読")
        // A receipt kept as text is read as a list, its turn in words.
        let turn = NotificationHistoryRowText.Lines(
            headline: "Turn finished",
            subject: "Add the tests",
            isSubjectAName: false,
            outcome: .headline,
            facts: [ReceiptRun(text: "T7 · 2 files +3 −1", role: .plain)]
        )
        #expect(NotificationHistoryRowText.spokenLabel(turn, timeLabel: "now", isUnread: false, locale: en)
            == "Add the tests, Turn finished, Turn 7, 2 files +3 −1, now")
        // A reply is said as one, and the headline the row no longer draws
        // is still read.
        let replied = NotificationHistoryRowText.Lines(
            headline: "Turn finished",
            subject: "Add the tests",
            isSubjectAName: false,
            outcome: .reply("Added two tests."),
            facts: [ReceiptRun(text: "T2", role: .plain)]
        )
        #expect(NotificationHistoryRowText.spokenLabel(replied, timeLabel: "now", isUnread: false, locale: en)
            == "Add the tests, Reply: Added two tests., Turn finished, Turn 2, now")
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
        let counted = [
            ReceiptRun(text: "T7", role: .plain),
            ReceiptRun(text: " ", role: .quiet),
            ReceiptRun(text: "+3", role: .added(isEmphasized: false)),
            ReceiptRun(text: " ", role: .quiet),
            ReceiptRun(text: "−0", role: .quiet)
        ]
        #expect(turn("T7 · 2 files +3 −0\nAdd the tests") == .turn(receipt: counted, instruction: "Add the tests", reply: nil))
        // Saying only that nothing changed goes, in either language.
        #expect(turn("T2 · 回答のみ") == .turn(receipt: [ReceiptRun(text: "T2", role: .plain)], instruction: nil, reply: nil))
        // A check keeps its words, and a failed one its red.
        #expect(turn("T4 · ファイルの変更なし · ✗ Tests")
            == .turn(
                receipt: [
                    ReceiptRun(text: "T4", role: .plain),
                    ReceiptRun(text: " ", role: .quiet),
                    ReceiptRun(text: "✗ Tests", role: .failed)
                ],
                instruction: nil,
                reply: nil
            ))
        // A first line that is no receipt is kept whole.
        #expect(turn("Summary · done\nAdd the tests")
            == .turn(receipt: [ReceiptRun(text: "Summary · done", role: .plain)], instruction: "Add the tests", reply: nil))
        #expect(turn("Add the tests") == .turn(receipt: [], instruction: "Add the tests", reply: nil))
        #expect(turn("Claude Code finished a turn") == .turn(receipt: [], instruction: nil, reply: nil))
        // A harness's prompt, quoted with its tags before events: no line.
        #expect(turn("T3 · Answer only\n<task-notification> <task-id>b1</task-id>")
            == .turn(receipt: [ReceiptRun(text: "T3", role: .plain)], instruction: nil, reply: nil))
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
