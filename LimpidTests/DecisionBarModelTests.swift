// DecisionBarModelTests.swift
// Limpid — what an agent pane's decision bar says, and which of the pane's items it is on.

import Foundation
import Testing
@testable import Limpid

@MainActor
struct DecisionBarModelTests {
    private static let english = Locale(identifier: "en")
    private static let japanese = Locale(identifier: "ja")
    private static let pane = UUID()

    /// The items in the order they arrived, each under an id of its kind.
    private static func items(_ kinds: [AttentionItemKind], provider: AgentKind = .claude) -> [AttentionItem] {
        AttentionItem.testList(kinds, pane: pane, provider: provider, filesRequestsByKey: true)
    }

    private static func model(_ input: DecisionBarContent.Input, locale: Locale = english) -> DecisionBarModel {
        DecisionBarModel(content: DecisionBarContent.make(input), locale: locale)
    }

    /// A run not matched to its hook yet (one restored at launch) is said
    /// as the sidebar row says it: unknown, never idle.
    @Test func atRest_aRunNotMatchedYet_isUnknown_asItsRowSays() {
        let agent = SessionRowFact.Agent(provider: .claude, state: .unknown, detail: nil)
        #expect(Self.model(.init(agent: agent)).text == "Unknown")
        #expect(Self.model(.init(agent: agent), locale: Self.japanese).text == "不明")
        #expect(Self.model(.init(agent: agent)).tone == .muted)
    }

    @Test func atRest_theBarSaysWhatTheAgentIsDoing_withoutATag() {
        let model = Self.model(.init(agent: .init(provider: .claude, state: .running, detail: "Bash: swift test")))
        #expect(model.tag == nil)
        #expect(model.tone == .muted)
        #expect(model.text == "Bash: swift test")
        #expect(model.countText == nil)

        let idle = Self.model(.init(agent: .init(provider: .codex, state: .idle, detail: nil)), locale: Self.japanese)
        #expect(idle.text == "待機中")
    }

    @Test func aRequestTheTerminalHas_isAnsweredThere_withoutATimeLeft() {
        let deadline = ServiceDeadline(deadlineMs: 522_000, serviceNowMs: 0, receivedAt: SuspendingClock().now)
        let handed = ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now), deadline: deadline)
        let model = Self.model(.init(items: Self.items([.approval(handed)]), approvalActions: [handed.key: .command]))
        #expect(model.tag == "Approval")
        #expect(model.tone == .waiting)
        #expect(model.text == "Claude wants to run a command.")
        #expect(model.instruction == "Answer in the terminal")
        #expect(model.heldUntil == nil, "the CLI's own deadline is not known here")

        // Past its time, it keeps saying so, in its short form too.
        let timedOut = Self.model(.init(items: Self.items([.approval(ApprovalFact.test(state: .timedOut))])))
        #expect(timedOut.instruction == "Timed out. Answer in the terminal.")
        #expect(timedOut.shortInstruction == "Timed out — answer in terminal")
        let timedOutJapanese = Self.model(.init(items: Self.items([.approval(ApprovalFact.test(state: .timedOut))])), locale: Self.japanese)
        #expect(timedOutJapanese.shortInstruction == "時間切れ（ターミナルで回答）")
    }

    @Test func aRequestLimpidHolds_isAnsweredOnTheCard_withItsTimeLeft() {
        let deadline = ServiceDeadline(deadlineMs: 522_000, serviceNowMs: 0, receivedAt: SuspendingClock().now)
        for state in [ApprovalRequestState.held, .sendFailed(.deny, error: "offline")] {
            let model = Self.model(.init(items: Self.items([.approval(ApprovalFact.test(state: state, deadline: deadline))])))
            #expect(model.instruction == "Answer on the approval card")
            // No shorter form: the card is not the terminal.
            #expect(model.shortInstruction == model.instruction)
            #expect(model.heldUntil == deadline)
        }
        #expect(DecisionBarModel.timeLeft(deadline, now: deadline.receivedAt, locale: Self.english) == "8:42 left")

        let edit = ApprovalFact.test(provider: .codex)
        let editModel = Self.model(
            .init(items: Self.items([.approval(edit)], provider: .codex), approvalActions: [edit.key: .fileChange]),
            locale: Self.japanese
        )
        #expect(editModel.text == "Codex がファイルの変更を求めています。")
        #expect(editModel.instruction == "承認カードで回答してください")
    }

    /// A held approval is named by its tool as an unheld one is: WebFetch,
    /// Task, or an MCP tool is neither a file change nor a command, and a
    /// request whose tool nothing names is not called a command.
    @Test(arguments: [
        (PromptApproval.Action?.some(.other), "en", "Claude is asking for approval."),
        (.other, "ja", "Claude が承認を求めています。"),
        (.command, "en", "Claude wants to run a command."),
        (nil, "en", "Claude is asking for approval.")
    ])
    func aHeldApproval_isNamedByItsTool_asAnUnheldOneIs(action: PromptApproval.Action?, language: String, text: String) {
        let approval = ApprovalFact.test()
        let actions = action.map { [approval.key: $0] } ?? [:]
        let input = DecisionBarContent.Input(items: Self.items([.approval(approval)]), approvalActions: actions)
        let model = Self.model(input, locale: Locale(identifier: language))
        #expect(model.text == text)
    }

    @Test func whileADecisionIsOnItsWay_theBarSaysWhereItGoes() {
        let delegating = ApprovalFact.test(state: .sending(.delegate, since: SuspendingClock().now))
        #expect(Self.model(.init(items: Self.items([.approval(delegating)]))).instruction == "Answer in the terminal")
        #expect(Self.model(.init(items: Self.items([.approval(delegating)]))).heldUntil == nil)

        let allowing = ApprovalFact.test(state: .sending(.allowOnce, since: SuspendingClock().now))
        let sending = Self.model(.init(items: Self.items([.approval(allowing)])))
        #expect(sending.instruction == "Sending…")
        #expect(sending.heldUntil == nil)
    }

    /// A wait in a tool's words reads as an approval, a file change or a
    /// command as the tool is one; a tool no list knows, which the record
    /// says is an approval, is one too. A question the record names reads as
    /// a held one does, whatever its words look like; a wait with no words
    /// is the state's own word.
    @Test(arguments: [
        (PromptWait(detail: "Write: /Users/me/repo/notes.txt"), AgentKind.claude, "en", "Approval", "Claude wants to change files."),
        (PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"), .claude, "ja", "承認", "Claude が承認を求めています。"),
        (PromptWait(detail: "Read: which file?", kind: .question, tool: nil), .claude, "en", "Question", "Claude is asking a question."),
        (PromptWait(detail: nil, kind: .question, tool: nil), .claude, "ja", "質問", "Claude が質問しています。"),
        (PromptWait(detail: "Bash"), .codex, "en", "Approval", "Codex wants to run a command."),
        (PromptWait(detail: "WebFetch"), .claude, "en", "Approval", "Claude is asking for approval."),
        (PromptWait(detail: "Edit: /a/b.swift"), .claude, "ja", "承認", "Claude がファイルの変更を求めています。"),
        (PromptWait(detail: "Read"), .claude, "ja", "承認", "Claude が承認を求めています。"),
        (PromptWait(detail: nil), .claude, "ja", "応答", "Claude が応答を待っています。")
    ])
    func aWaitLimpidDoesNotHold_isTaggedAndWorded_byItsKindAndTool(
        wait: PromptWait,
        provider: AgentKind,
        language: String,
        tag: String,
        text: String
    ) {
        let model = Self.model(.init(items: Self.items([.prompt(wait)], provider: provider)), locale: Locale(identifier: language))
        #expect(model.tag == tag)
        #expect(model.text == text)
    }

    /// The tool's words are in the tooltip rather than pushing the
    /// instruction out, and the bar's own sentence is cut at its end, like
    /// any.
    @Test func aWaitInAToolsWords_keepsThemInTheTooltip_andTheInstructionWhole() {
        let write = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Write: /Users/me/repo/notes.txt"))])))
        #expect(write.tone == .waiting)
        #expect(write.instruction == "Answer in the terminal")
        #expect(write.textHelp == "Write: /Users/me/repo/notes.txt")
        #expect(!write.cutsTextInMiddle)
        #expect(write.shortInstruction == "Answer in terminal")

        let monitor = Self.model(
            .init(items: Self.items([.prompt(PromptWait(detail: "Monitor", kind: .approval, tool: "Monitor"))])),
            locale: Self.japanese
        )
        #expect(monitor.shortInstruction == "ターミナルで回答")
        let asked = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Read: which file?", kind: .question, tool: nil))])))
        #expect(asked.instruction == "Answer in the terminal")
        #expect(asked.textHelp == "Read: which file?")
        #expect(!asked.cutsTextInMiddle)
        let japanese = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Edit: /a/b.swift"))])), locale: Self.japanese)
        #expect(japanese.instruction == "ターミナルで回答してください")
    }

    @Test func aQuestion_aWaitAtThePrompt_aStop_andAnUnreadTurn_sayTheirOwnWords() {
        let handed = ApprovalFact.test(isQuestion: true, state: .handedToTerminal(since: SuspendingClock().now))
        let question = Self.model(.init(items: Self.items([.question(handed)])))
        #expect(question.tag == "Question")
        #expect(question.text == "Claude is asking a question.")
        #expect(question.instruction == "Answer in the terminal")

        let prompt = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: nil))], provider: .codex)))
        // Neither an approval nor a question we know of: the state's own word.
        #expect(prompt.tag == "Response")
        #expect(prompt.shortInstruction == "Answer in terminal")
        #expect(prompt.text == "Codex is waiting for a response.")
        #expect(prompt.instruction == "Answer in the terminal")
        let worded = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Allow network access?"))])))
        #expect(worded.text == "Allow network access?")
        #expect(worded.textHelp == "Allow network access?")
        #expect(worded.cutsTextInMiddle)

        let stop = Self.model(.init(items: Self.items([.stop(.processExited)])))
        #expect(stop.tag == "Stopped")
        #expect(stop.tone == .stopped)
        #expect(stop.instruction == nil)
        #expect(stop.shortInstruction == nil)
        // Only a prompt's own words are cut in the middle or put in the tooltip.
        #expect(!stop.cutsTextInMiddle)
        #expect(stop.textHelp == nil)
        #expect(!question.cutsTextInMiddle)
        #expect(question.textHelp == nil)
        #expect(question.shortInstruction == "Answer in terminal")
        // The tag says "Stopped"; the words say why, once.
        #expect(stop.text == "The process exited unexpectedly.")
        #expect(stop.runs == [ReceiptRun(text: stop.text, role: .emphasized)])
        let unworded = Self.model(.init(items: Self.items([.stop(.error(nil))])), locale: Self.japanese)
        #expect(unworded.text == "エージェントが停止しました。", "never an empty line, nor 停止 twice")

        let unread = Self.model(.init(items: Self.items([.unread(UnreadTurn(
            turnID: TurnID("t"),
            changes: .unknown
        ))])))
        #expect(unread.tag == "Unread")
        #expect(unread.text == "The turn finished", "the tag already says unread")
    }

    @Test func aWaitAtThePrompt_isNamedAlsoPending_asItsRowNamesIt() throws {
        for (wait, english, japanese) in [
            (PromptWait(detail: "Which color?", kind: .question, tool: nil), "Question also pending", "回答待ちもあります"),
            (PromptWait(detail: "Allow network access?"), "Response also pending", "応答待ちもあります"),
            (PromptWait(detail: "Bash: ls", kind: .approval, tool: "Bash"), "Approval also pending", "承認待ちもあります")
        ] {
            let items = Self.items([.stop(.processExited), .prompt(wait)])
            let stopID = try #require(items.first?.id)
            #expect(Self.model(.init(items: items, selected: stopID)).countText == "1 / 2 · \(english)")
            #expect(Self.model(.init(items: items, selected: stopID), locale: Self.japanese).countText?.hasSuffix(japanese) == true)
        }
    }

    @Test func aPaneWithTwoItems_countsThemInTheOrderTheyArrived() throws {
        // The stop arrived first, the approval after it.
        let handed = ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now))
        let items = Self.items([.stop(.processExited), .approval(handed)])
        let stopID = try #require(items.first?.id)
        let approvalID = try #require(items.last?.id)

        let unchosen = Self.model(.init(items: items))
        #expect(unchosen.tag == "Approval", "unchosen, the highest-ranked item")
        #expect(unchosen.countText == "2 / 2")

        let onStop = Self.model(.init(items: items, selected: stopID))
        #expect(onStop.tag == "Stopped")
        #expect(onStop.countText == "1 / 2 · Approval also pending")
        #expect(onStop.countSpokenText == "Needs Attention in this pane: 1 of 2, Approval also pending")
        #expect(Self.model(.init(items: items, selected: stopID), locale: Self.japanese).countSpokenText
            == "このペインの要対応、2 件中 1 件目、承認待ちもあります")
        #expect(Self.model(.init(items: items, selected: stopID), locale: Self.japanese).countText == "1 / 2 · 承認待ちもあります")

        #expect(DecisionBarContent.next(after: stopID, in: items) == approvalID)
        #expect(DecisionBarContent.next(after: approvalID, in: items) == stopID, "it wraps")
    }

    @Test func twoOfTheSameKind_addNoAlsoPending() throws {
        let handed = ApprovalRequestState.handedToTerminal(since: SuspendingClock().now)
        let items = Self.items([.approval(ApprovalFact.test(state: handed)), .approval(ApprovalFact.test(state: handed))])
        let second = try #require(items.last?.id)
        #expect(Self.model(.init(items: items, selected: second)).countText == "2 / 2")
    }

    @Test func rightAfterAnAnswerInTheTerminal_theBarSaysSo_andWhereCommandJGoesNext() {
        let nextID = AttentionItemID.stop(EpisodeKey(origin: .runtime("build"), episodeToken: "1"))
        let next = DecisionBarModel(
            content: DecisionBarContent.make(.init(done: .init(result: .answeredInTerminal, next: nextID))),
            locale: Self.english
        ) { $0 == nextID ? "build" : nil }
        // The row leads with a muted checkmark (`everyDoneLine_hasNoTag`),
        // and the sentence says what happened.
        #expect(next.text == "Answered in the terminal. Next: “build” (⌘J).")

        let none = Self.model(.init(done: .init(result: .answeredInTerminal, next: nil)), locale: Self.japanese)
        #expect(none.text == "ターミナルで回答しました。要対応はありません。")
        let nextInJapanese = DecisionBarModel(
            content: DecisionBarContent.make(.init(done: .init(result: .answeredInTerminal, next: nextID))),
            locale: Self.japanese
        ) { $0 == nextID ? "build" : nil }
        #expect(nextInJapanese.text == "ターミナルで回答しました。次は「build」（⌘J）。")
    }

    /// Every line after an item was handled leads with the muted check in
    /// place of a tag (muted, not green, since no state is drawn in green),
    /// in either language.
    @Test(arguments: [
        DecisionBarContent.DoneResult.answeredInTerminal,
        .declinedInTerminal,
        .markedViewed(ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())),
        .insertedReview(agent: .codex),
        .resumed,
        .restored(RestoreDone(opID: "OP", root: "/repo", turnNumber: 3))
    ])
    func everyDoneLine_hasNoTag(_ result: DecisionBarContent.DoneResult) {
        for locale in [Self.english, Self.japanese] {
            let model = Self.model(.init(done: .init(result: result, next: nil)), locale: locale)
            #expect(model.tag == nil)
            #expect(model.tone == .done)
            #expect(!model.text.isEmpty)
        }
    }

    @Test func theDoneLine_comesOnlyWhenAPaneIsLeftWithNothing_afterAnAnswerAtTheTerminal() {
        let handed = Self.items([.approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now)))])
        let held = Self.items([.approval(ApprovalFact.test())])
        let stop = Self.items([.stop(.processExited)])
        let prompt = Self.items([.prompt(PromptWait(detail: nil))])

        #expect(DecisionBarModel.doneUpdate(lastShown: handed.first, items: [], hasMovedOnSinceShown: false) == .set(.answeredInTerminal))
        // Limpid's time ran out and the terminal took it: answered there too.
        let timedOut = Self.items([.approval(ApprovalFact.test(state: .timedOut))])
        #expect(DecisionBarModel.doneUpdate(lastShown: timedOut.first, items: [], hasMovedOnSinceShown: false) == .set(.answeredInTerminal))
        #expect(DecisionBarModel.doneUpdate(lastShown: prompt.first, items: [], hasMovedOnSinceShown: false) == .set(.answeredInTerminal))
        // Answered on the card, or a stop that cleared: the card or the pane says so.
        #expect(DecisionBarModel.doneUpdate(lastShown: held.first, items: [], hasMovedOnSinceShown: false) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: stop.first, items: [], hasMovedOnSinceShown: false) == .keep)
        // Something still waits, or arrived: the bar shows it instead.
        #expect(DecisionBarModel.doneUpdate(lastShown: handed.first, items: stop, hasMovedOnSinceShown: false) == .clear)
        #expect(DecisionBarModel.doneUpdate(lastShown: nil, items: [], hasMovedOnSinceShown: false) == .keep)
    }

    @Test func noDoneLine_whenTheItemLeftAsThePaneMovedOn() {
        let prompt = Self.items([.prompt(PromptWait(detail: nil))])
        let handed = Self.items([.approval(ApprovalFact.test(state: .handedToTerminal(since: SuspendingClock().now)))])

        // The person quit the agent at its prompt, or sent the next prompt:
        // in the same pass the pane moved on and the item left.
        #expect(DecisionBarModel.doneUpdate(lastShown: prompt.first, items: [], hasMovedOnSinceShown: true) == .keep)
        #expect(DecisionBarModel.doneUpdate(lastShown: handed.first, items: [], hasMovedOnSinceShown: true) == .keep)
        // An item arriving still takes the bar back.
        #expect(DecisionBarModel.doneUpdate(lastShown: handed.first, items: prompt, hasMovedOnSinceShown: true) == .clear)
    }

    @Test func afterAnInsert_theBarSaysWhereTheCommentsWent_overThePanesItems() {
        let items = Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))])
        let done = DecisionBarContent.Done(result: .insertedReview(agent: .claude), next: nil)

        let model = Self.model(.init(items: items, done: done))
        #expect(model.tag == nil)
        #expect(model.tone == .done)
        #expect(model.text == "Inserted the comments into Claude’s input. Press Return to send.")
        #expect(model.primaryAction == nil, "Return sends them; ⌘⏎ has nothing to press here")
        let japanese = Self.model(.init(items: items, done: done), locale: Self.japanese)
        #expect(japanese.text == "コメントを Claude の入力欄に挿入しました。Return を押すと送信されます。")
        // An item the person chose takes the bar back.
        let chosen = Self.model(.init(items: items, selected: items.first?.id, done: done))
        #expect(chosen.tag == "Unread")
        // Never over anything but unread turns: an approval, a stop, or a
        // prompt that Return would answer keeps the bar.
        let approval = Self.model(.init(items: Self.items([.approval(ApprovalFact.test())]), done: done))
        #expect(approval.tag == "Approval")
        let stopped = Self.model(.init(items: Self.items([.stop(.processExited)]), done: done))
        #expect(stopped.tag == "Stopped")
        let needsInput = Self.model(.init(items: Self.items([.prompt(PromptWait(detail: "Allow edit?"))]), done: done))
        #expect(needsInput.tone != .done, "a permission the terminal asks itself is answered with Return")
        #expect(!DecisionBarContent.shows(.insertedReview(agent: .claude), over: Self.items([.prompt(PromptWait(detail: nil))])))
        // Its items changing ends it.
        #expect(DecisionBarModel.doneUpdate(lastShown: nil, items: items, hasMovedOnSinceShown: false) == .clear)
    }

    @Test func anUnreadTurn_offersMarkAsViewed_asTheButtonCommandReturnPresses() throws {
        let items = Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unknown))])
        let itemID = try #require(items.first?.id)

        #expect(Self.model(.init(items: items)).primaryAction == .markReviewed(itemID, throughTurn: nil))
        // A turn that may have changed files waits for the person; one known
        // to have changed none, or whose changes could not be read, is read
        // by opening its pane.
        for changes: ChangeSummary in [.changed(files: 1, added: 1, removed: 0), .pending] {
            let mayHaveChanged = Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: changes))])
            #expect(Self.model(.init(items: mayHaveChanged)).primaryAction == mayHaveChanged.first.map { .markReviewed(
                $0.id,
                throughTurn: nil
            ) })
        }
        for changes: ChangeSummary in [.unchanged, .unavailable(reason: "notGit")] {
            let changedNothing = Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: changes))])
            #expect(Self.model(.init(items: changedNothing)).primaryAction == nil)
        }
        // Nothing else has one here: requests are answered in the terminal
        // or on the card, and this stop has no resume to offer (no
        // `stopResumes`).
        #expect(Self.model(.init(items: Self.items([.stop(.processExited)]))).primaryAction == nil)
        #expect(Self.model(.init(items: Self.items([.approval(ApprovalFact.test())]))).primaryAction == nil)
        #expect(Self.model(.init()).primaryAction == nil)
    }

    @Test func reviewChanges_isOfferedBesideMarkAsViewed_onTheSameTurns() {
        let conversation = TurnSummaryFixture.conversation
        for changes: ChangeSummary in [.changed(files: 1, added: 1, removed: 0), .unknown, .pending] {
            let unread = UnreadTurn(turnID: TurnID("t"), changes: changes, conversation: conversation)
            let bar = Self.model(.init(items: Self.items([.unread(unread)])))
            #expect(bar.offersReview)
            #expect(bar.reviewConversation == conversation, "the bar's own conversation, not the pane's found again")
        }
        for changes: ChangeSummary in [.unchanged, .unavailable(reason: "notGit")] {
            let bar = Self.model(.init(items: Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: changes))])))
            #expect(!bar.offersReview)
        }
        #expect(!Self.model(.init(items: Self.items([.approval(ApprovalFact.test())]))).offersReview)
        #expect(!Self.model(.init()).offersReview)
    }

    @Test func recordedTurns_areTaggedWithTheirNumbers_andGiveTheirReceipt() {
        let check = CheckSummary(command: "make test", isFiltered: true, exitCode: 0)
        let changed = UnreadTurn(
            turnID: TurnID("T6"),
            numbers: 6...7,
            changes: .changed(files: 2, added: 94, removed: 2),
            check: check,
            conversation: TurnSummaryFixture.conversation
        )
        let bar = Self.model(.init(items: Self.items([.unread(changed)])))
        #expect(bar.tag == "T6–T7")
        #expect(bar.text == "2 files +94 −2 · ✓ Tests (filtered)")
        // VoiceOver hears the turns as words and the facts as a list.
        #expect(bar.spokenTag == "Turns 6 to 7")
        #expect(bar.spokenText == "2 files +94 −2, ✓ Tests (filtered)")
        let japanese = Self.model(.init(items: Self.items([.unread(changed)])), locale: Self.japanese)
        #expect(japanese.spokenTag == "ターン 6 から 7")
        #expect(Self.model(.init(items: Self.items([.unread(changed)])), locale: Self.japanese).tag == "T6〜T7")

        let untaken = UnreadTurn(turnID: TurnID("T5"), numbers: 5...5, changes: .unavailable(reason: "notGit"))
        let notTaken = Self.model(.init(items: Self.items([.unread(untaken)])))
        #expect(notTaken.text == "Couldn’t get the changes")
        #expect(notTaken.primaryAction == nil)
    }

    @Test func aTurnThatOnlyAnswered_isNoItemOfTheBar_whichGivesItsReceiptAtRest() {
        let answered = UnreadTurn(turnID: TurnID("T3"), numbers: 3...3, changes: .unchanged)
        let resting = SessionRowFact.Agent(provider: .claude, state: .finished, detail: nil)

        let bar = Self.model(.init(items: Self.items([.unread(answered)]), agent: resting, lastTurn: answered))

        #expect(bar.content.itemID == nil)
        #expect(bar.tag == nil)
        #expect(bar.tone == .muted)
        #expect(bar.text == "T3 · No file changes")
        #expect(bar.spokenText == "Turn 3, No file changes")
        #expect(Self.model(.init(items: Self.items([.unread(answered)]), agent: resting, lastTurn: answered), locale: Self.japanese)
            .spokenText == "ターン 3、ファイルの変更なし")
        // While the agent works, what it does says more.
        let working = SessionRowFact.Agent(provider: .claude, state: .running, detail: "Bash: swift test")
        #expect(Self.model(.init(agent: working, lastTurn: answered)).text == "Bash: swift test")
    }

    @Test func aTurnThatOnlyAnswered_isNeitherCountedNorStepped_beside_aChange() throws {
        let changed = UnreadTurn(turnID: TurnID("T5"), numbers: 5...5, changes: .changed(files: 1, added: 1, removed: 0))
        let answered = UnreadTurn(turnID: TurnID("T6"), numbers: 6...6, changes: .unchanged)
        let items = Self.items([.unread(changed), .unread(answered)])
        let changedID = try #require(items.first?.id)

        let bar = Self.model(.init(items: items))

        #expect(bar.content.itemID == changedID)
        #expect(bar.countText == nil, "one item for the bar")
        #expect(DecisionBarContent.next(after: changedID, in: items) == changedID)
    }

    @Test func markAsViewed_namesTheLastTurnShown_soATurnJoiningLaterWaitsAgain() throws {
        let shown = UnreadTurn(turnID: TurnID("T6"), numbers: 6...7, changes: .changed(files: 2, added: 2, removed: 0))
        let grown = UnreadTurn(turnID: TurnID("T6"), numbers: 6...8, changes: .changed(files: 3, added: 3, removed: 0))
        let before = Self.model(.init(items: Self.items([.unread(shown)])))
        let after = Self.model(.init(items: Self.items([.unread(grown)])))
        let itemID = try #require(before.content.itemID)

        #expect(before.primaryAction == .markReviewed(itemID, throughTurn: 7))
        #expect(after.primaryAction == .markReviewed(itemID, throughTurn: 8))
        #expect(before.primaryAction != after.primaryAction, "the gate starts its wait over")
    }

    @Test func rightAfterMarkingViewed_theBarSaysSo_withUndo() {
        let undo = ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())
        let english = Self.model(.init(done: .init(result: .markedViewed(undo), next: nil)))
        #expect(english.text == "Marked as viewed. Nothing needs attention.")
        #expect(english.undo == undo)
        #expect(english.primaryAction == nil)

        let japanese = Self.model(.init(done: .init(result: .markedViewed(undo), next: nil)), locale: Self.japanese)
        #expect(japanese.text == "確認済みにしました。要対応はありません。")
        #expect(Self.model(.init(done: .init(result: .answeredInTerminal, next: nil))).undo == nil)
    }

    @Test func aPaneWithNoAgent_hasNoBar() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let window = ProjectWindowState(selection: session.primarySelection)
        let sources = DecisionBarModel.Sources(
            session: session,
            window: window,
            queue: AttentionQueue(),
            runtimes: [],
            approvals: ApprovalLedger(),
            next: nil
        )
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english) == nil)

        session.update(session.tab(containing: pane)?.id ?? UUID()) { tab in
            tab.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date())]
        }
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)?.text == "Idle")
    }

    /// When the runtimes list an idle run before a running one in the same
    /// pane, the bar speaks for the running one, as the pane's header mark
    /// does.
    @Test func aPaneWithAnIdleRunListedBeforeARunningOne_speaksForTheRunningOne() {
        let (session, _, pane) = WorkspaceSessionFixture.withLooseTab()
        let finished = AgentRuntimePresentation.test(
            kind: .claude,
            runID: "a",
            badge: AgentBadge(state: .idle, updatedAt: Date()),
            paneIDs: [pane]
        )
        let running = AgentRuntimePresentation.test(
            kind: .codex,
            runID: "b",
            badge: AgentBadge(state: .running, detail: "Bash: make test", updatedAt: Date()),
            paneIDs: [pane]
        )
        let sources = DecisionBarModel.Sources(
            session: session,
            window: ProjectWindowState(selection: session.primarySelection),
            queue: AttentionQueue(),
            runtimes: [finished, running],
            approvals: ApprovalLedger(),
            next: nil
        )
        #expect(DecisionBarModel.runtime(in: pane, runtimes: sources.runtimes)?.id == running.id)
        #expect(DecisionBarModel(paneID: pane, sources: sources, locale: Self.english)?.text == "Bash: make test")
    }

    @Test func theNextItem_namesItsProject_onlyWhenItIsAnotherProjects() throws {
        let (session, project) = WorkspaceSessionFixture.withProject(name: "limpid")
        let tab = session.openTab(container: .project(project.id))
        let pane = try #require(tab.splitTree.allLeafIDs().first)
        session.update(tab.id) { $0.titleOverride = "build" }
        session.update(tab.id) { $0.agentBadges[.claude] = [pane: AgentBadge(state: .idle, updatedAt: Date())] }
        let window = ProjectWindowState(selection: session.primarySelection)
        window.decisionBarDone[pane] = .answeredInTerminal
        var queue = AttentionQueue()
        queue.insert(
            id: .stop(EpisodeKey(origin: .runtime("r"), episodeToken: "1")),
            kind: .stop(.processExited),
            subject: .runtime(id: "r", provider: .claude, paneID: UUID(), tabID: tab.id, projectID: project.id),
            arrivedAt: Date()
        )
        let next = try #require(queue.items.first)

        func model(windowProjectID: UUID?) -> DecisionBarModel? {
            DecisionBarModel(
                paneID: pane,
                sources: .init(
                    session: session,
                    window: window,
                    queue: AttentionQueue(),
                    runtimes: [],
                    approvals: ApprovalLedger(),
                    next: (next, windowProjectID)
                ),
                locale: Self.english
            )
        }
        func text(windowProjectID: UUID?) -> String? {
            model(windowProjectID: windowProjectID)?.text
        }
        // The row is named, so its place adds its folder: the fixture's
        // folder is not the project's name.
        let folder = project.rootURL.lastPathComponent
        #expect(text(windowProjectID: project.id) == "Answered in the terminal. Next: “build” (⌘J).")
        #expect(text(windowProjectID: nil) == "Answered in the terminal. Next: “build · limpid / \(folder)” (⌘J).")
        // VoiceOver hears neither the key's symbols nor the separator.
        #expect(model(windowProjectID: nil)?.spokenText == "Answered in the terminal. Next: “build, limpid / \(folder)”.")
    }

    // MARK: - Usage limit stops

    private static let usageLimitReset = Date(timeIntervalSince1970: 1_790_003_600)
    private static let usageLimit = UsageLimit(resetAt: usageLimitReset, window: "five_hour")
    /// An hour before the reset, so the bar names it.
    private static let beforeReset = usageLimitReset.addingTimeInterval(-3600)

    private static func usageLimitBar(
        _ notice: UsageLimitResetNotice?,
        now: Date = beforeReset,
        locale: Locale = english
    ) -> DecisionBarModel {
        let item = AttentionItem.testUsageLimitStop(usageLimit, arrivedAt: Self.beforeReset)
        let content = DecisionBarContent.make(.init(
            items: [item],
            agent: .init(provider: .claude, state: .error, detail: nil),
            stopResumes: [item.id: .available]
        ))
        return DecisionBarModel(content: content, resetNotice: notice, now: now, locale: locale)
    }

    @Test func usageLimitStop_offersTheNoticeInPlaceOfResumingWhileTheLimitHolds() throws {
        let offered = Self.usageLimitBar(.offered)
        let itemID = try #require(offered.content.itemID)
        #expect(offered.primaryAction == .notifyAtReset(itemID))
        #expect(!offered.text.contains("The conversation is saved."))

        let requested = Self.usageLimitBar(.requested)
        #expect(requested.primaryAction == nil)
        let resetTime = StopReasonText.resetTime(Self.usageLimitReset, locale: Self.english, now: Self.beforeReset)
        #expect(requested.text == "5-hour limit reached · resets \(resetTime). You’ll be notified when it resets.")
        let japaneseTime = StopReasonText.resetTime(Self.usageLimitReset, locale: Self.japanese, now: Self.beforeReset)
        #expect(
            Self.usageLimitBar(.requested, locale: Self.japanese).text
                == "5 時間枠の上限に達しました · \(japaneseTime) に解除。解除されたら通知します。"
        )
        // The bar is worded at the time it is given: past the reset, the
        // time goes from the limit's sentence.
        let past = Self.usageLimitBar(nil, now: Self.usageLimitReset.addingTimeInterval(1))
        #expect(past.text == "5-hour limit reached. The conversation is saved.")
        // Only the reason is set apart; what follows it reads plain.
        #expect(past.runs == [
            ReceiptRun(text: "5-hour limit reached", role: .emphasized),
            ReceiptRun(text: ". The conversation is saved.", role: .plain)
        ])

        // Once the provider is free (or with no time known) it resumes as
        // any stop, the sentences set apart.
        let free = Self.usageLimitBar(nil)
        #expect(free.primaryAction == .resume(itemID))
        #expect(free.text.contains(". The conversation is saved."))
    }

    @Test func usageLimitNotice_isNotTheBarsOnAnotherStop() {
        let item = AttentionItem.testUsageLimitStop(nil, arrivedAt: Self.beforeReset)
        let content = DecisionBarContent.make(.init(
            items: [item],
            agent: .init(provider: .claude, state: .error, detail: nil),
            stopResumes: [item.id: .available]
        ))
        // The bar is handed a notice only for its usage limit stop; any
        // other stop it shows resumes.
        #expect(DecisionBarModel(content: content, locale: Self.english).primaryAction == .resume(item.id))
    }

    // MARK: - The unread turns' ⋯

    @Test func unreadTurnsThatMayHaveChangedFiles_offerARestoreToTheFirstOfThem() {
        let changed = ChangeSummary.changed(files: 1, added: 3, removed: 1)
        func entry(numbers: ClosedRange<Int>?, changes: ChangeSummary, conversation: ConversationKey?) -> DecisionBarModel.RestoreEntry? {
            let unread = UnreadTurn(turnID: TurnID("T5"), numbers: numbers, changes: changes, conversation: conversation)
            return Self.model(.init(items: Self.items([.unread(unread)]))).restoreEntry(locale: Self.english)
        }
        let conversation = TurnSummaryFixture.conversation

        let one = entry(numbers: 5...5, changes: changed, conversation: conversation)
        #expect(one?.turnID == TurnID("T5"))
        #expect(one?.title == "Restore Code to Before This Turn…")
        // Several turns: "this turn" would not say which.
        #expect(entry(numbers: 5...7, changes: changed, conversation: conversation)?.title == "Restore Code to Before T5…")
        #expect(entry(numbers: 5...5, changes: .unchanged, conversation: conversation) == nil, "nothing to take back")
        #expect(entry(numbers: nil, changes: changed, conversation: nil) == nil, "no turn record stands for it")
    }

    // MARK: - The row in each fit

    /// Unread turns: folded, "Review Unviewed" heads the ⋯ and "⌘⏎" goes;
    /// at the least, the tag goes too and the count moves into the ⋯,
    /// above what shows something, with the restore apart at the end.
    @Test func unreadTurns_foldIntoTheMoreMenu_inTurn() throws {
        let unread = UnreadTurn(
            turnID: TurnID("T5"),
            numbers: 5...5,
            changes: .changed(files: 1, added: 3, removed: 1),
            conversation: TurnSummaryFixture.conversation
        )
        let items = Self.items([.unread(unread), .stop(.processExited)])
        let shown = try #require(items.first {
            if case .unread = $0.kind {
                true
            } else {
                false
            }
        })
        let bar = Self.model(.init(items: items, selected: shown.id))
        let entry = try #require(bar.restoreEntry(locale: Self.english))
        #expect(bar.countText != nil)
        #expect(bar.fits(locale: Self.english) == DecisionBarModel.Fit.allCases)

        let full = bar.shape(.full, locale: Self.english)
        #expect(full.showsTag && full.showsCount && full.showsReview && full.showsKeyHint)
        #expect(full.moreSections == [[.restore(entry)]])

        let folded = bar.shape(.folded, locale: Self.english)
        #expect(folded.showsTag && folded.showsCount)
        #expect(!folded.showsReview && !folded.showsKeyHint)
        #expect(folded.moreSections == [[.review], [.restore(entry)]])

        let minimal = bar.shape(.minimal, locale: Self.english)
        #expect(!minimal.showsTag && !minimal.showsCount)
        // "Mark as Viewed" is short as it is.
        #expect(!minimal.usesShortLabels)
        #expect(minimal.moreSections == [[.showNext], [.review], [.restore(entry)]])
        #expect(minimal.showsButtons && !minimal.keepsWordsFloor)
        #expect(full.keepsWordsFloor && folded.keepsWordsFloor)

        // Too narrow for any button: the words alone, and no ⋯; ⌘⏎ still
        // presses the primary action.
        let wordsOnly = bar.shape(.wordsOnly, locale: Self.english)
        #expect(!wordsOnly.showsButtons && !wordsOnly.showsTag && !wordsOnly.showsCount)
        #expect(wordsOnly.moreSections.isEmpty)
        #expect(bar.primaryAction != nil)
    }

    /// A stop keeps its ⋯ in every fit that shows buttons; at the least,
    /// without its tag, it resumes in the short form.
    @Test func aStop_keepsItsMoreMenu_andShortensItsResume() throws {
        let items = Self.items([.stop(.processExited)])
        let item = try #require(items.first)
        let bar = Self.model(.init(items: items, stopResumes: [item.id: .available]))
        #expect(bar.fits(locale: Self.english) == DecisionBarModel.Fit.allCases)
        for fit in [DecisionBarModel.Fit.full, .folded, .minimal] {
            let shape = bar.shape(fit, locale: Self.english)
            #expect(!shape.showsReview)
            #expect(shape.moreSections == [[.showPartialChanges(item.id), .startNewConversation(item.id)]])
            #expect(shape.usesShortLabels == (fit == .minimal))
        }
    }

    /// A workspace whose worktree is gone offers to close its tabs, and
    /// nothing a stopped conversation offers: there is no folder to resume
    /// or start in.
    @Test func aMissingWorktree_offersToCloseItsTabs() throws {
        let items = Self.items([.stop(.worktreeMissing)])
        let item = try #require(items.first)
        let bar = Self.model(.init(items: items))
        #expect(bar.tag == "Stopped")
        #expect(bar.text == "Worktree not found.")
        #expect(bar.primaryAction == .closeAllTabs(item.id))
        #expect(bar.stopItem == nil)
        #expect(bar.shape(.full, locale: Self.english).moreSections.isEmpty)
        #expect(Self.model(.init(items: items), locale: Self.japanese).text == "ワークツリーが見つかりません。")
    }

    /// A bar with no buttons has one fit, so it draws its row once.
    @Test func barsWithoutButtons_haveOneFit() {
        let bars = [
            Self.model(.init()),
            Self.model(.init(items: Self.items([.approval(ApprovalFact.test())]))),
            Self.model(.init(items: Self.items([.unread(UnreadTurn(turnID: TurnID("t"), changes: .unchanged))])))
        ]
        for bar in bars {
            #expect(bar.fits(locale: Self.english) == [.full], "\(bar.text)")
            #expect(bar.shape(.full, locale: Self.english).moreSections.isEmpty, "\(bar.text)")
        }
    }

    /// The line after Mark as Viewed has only its Undo to keep: it stays
    /// while it fits at all, then the line keeps its words alone.
    @Test func theLineAfterMarkAsViewed_keepsItsUndo_untilNothingFits() {
        let undo = ViewedLineUndo(conversation: TurnSummaryFixture.conversation, changeID: UUID())
        let bar = Self.model(.init(done: .init(result: .markedViewed(undo), next: nil)))
        #expect(bar.fits(locale: Self.english) == [.full, .minimal, .wordsOnly])
        #expect(bar.shape(.full, locale: Self.english).moreSections.isEmpty)
    }
}
