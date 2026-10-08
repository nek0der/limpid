// PromptCacheTests.swift
// Limpid — the prompt cache window: status boundaries, the single timer's
// aim, display strings, decoding from the projection, which clock each place
// shows, what its panel's answers do, and when the panel opens by itself.
// The panel's pure rules and presentation are in `PromptCachePanelTests`.

import Foundation
import Testing
@testable import Limpid

// MARK: - Status and formatting

struct PromptCacheStatusTests {
    private let anchor = Date(timeIntervalSince1970: 1_000_000)

    private func window(ttl: Int = 3600, tokens: Int? = 573_000) -> AgentCacheWindow {
        AgentCacheWindow(observedAt: anchor, ttlSeconds: ttl, rewriteTokens: tokens, precision: .estimated)
    }

    private func status(_ window: AgentCacheWindow?, secondsAfterAnchor: TimeInterval, running: Bool = false)
        -> PromptCacheStatus
    {
        PromptCacheStatus.status(
            window: window,
            now: anchor.addingTimeInterval(secondsAfterAnchor),
            isRunningTurn: running
        )
    }

    @Test func status_withoutWindow_isHidden() {
        #expect(status(nil, secondsAfterAnchor: 0) == .hidden)
        #expect(status(window(ttl: 0), secondsAfterAnchor: 10) == .hidden)
    }

    @Test func status_whileTurnRuns_isHiddenEvenWhenExpired() {
        #expect(status(window(), secondsAfterAnchor: 7200, running: true) == .hidden)
        #expect(status(window(), secondsAfterAnchor: 3500, running: true) == .hidden)
    }

    @Test func status_fiveMinutesOrMoreLeft_isValid() {
        #expect(status(window(), secondsAfterAnchor: 0) == .valid)
        #expect(status(window(), secondsAfterAnchor: 3600 - 300) == .valid)
    }

    @Test func status_underFiveMinutesLeft_isExpiringSoon() {
        #expect(status(window(), secondsAfterAnchor: 3600 - 299) == .expiringSoon)
        #expect(status(window(), secondsAfterAnchor: 3599) == .expiringSoon)
    }

    @Test func warningLead_isAFifthOfTheWindowAtMostFiveMinutes() {
        #expect(PromptCacheStatus.warningLead(ttlSeconds: 3600) == 300, "an hour warns five minutes ahead")
        #expect(PromptCacheStatus.warningLead(ttlSeconds: 300) == 60, "five minutes warn one minute ahead")
        // A five-minute window is not yellow from the moment its turn ends.
        #expect(status(window(ttl: 300), secondsAfterAnchor: 1) == .valid)
        #expect(status(window(ttl: 300), secondsAfterAnchor: 240) == .valid)
        #expect(status(window(ttl: 300), secondsAfterAnchor: 241) == .expiringSoon)
    }

    @Test func nextTransition_aimsAtTheScaledLead() {
        let short = window(ttl: 300)
        #expect(PromptCacheStatus.nextTransition(of: short, after: anchor) == anchor.addingTimeInterval(240))
        #expect(
            PromptCacheStatus.nextTransition(of: short, after: anchor.addingTimeInterval(240))
                == anchor.addingTimeInterval(300)
        )
    }

    @Test func status_atAndAfterExpiry_isExpired() {
        #expect(status(window(), secondsAfterAnchor: 3600) == .expired)
        #expect(status(window(), secondsAfterAnchor: 86400) == .expired)
    }

    @Test func nextTransition_walksWarningThenExpiryThenNothing() {
        let window = window()
        let warning = anchor.addingTimeInterval(3300)
        let expiry = anchor.addingTimeInterval(3600)
        #expect(PromptCacheStatus.nextTransition(of: window, after: anchor) == warning)
        #expect(PromptCacheStatus.nextTransition(of: window, after: warning) == expiry)
        #expect(PromptCacheStatus.nextTransition(of: window, after: expiry) == nil)
    }

    @Test func nextTransition_acrossWindows_isTheSoonest() {
        let later = window()
        let sooner = AgentCacheWindow(
            observedAt: anchor.addingTimeInterval(-3000),
            ttlSeconds: 3600,
            rewriteTokens: nil,
            precision: .reported
        )
        let next = PromptCacheStatus.nextTransition(of: [later, sooner], after: anchor)
        #expect(next == anchor.addingTimeInterval(300))
        #expect(PromptCacheStatus.nextTransition(of: [], after: anchor) == nil)
    }

    @Test func tokens_roundToThreeSignificantDigits() {
        #expect(PromptCacheFormatting.tokens(0) == "0")
        #expect(PromptCacheFormatting.tokens(999) == "999")
        #expect(PromptCacheFormatting.tokens(1000) == "1k")
        #expect(PromptCacheFormatting.tokens(573_400) == "573k")
        #expect(PromptCacheFormatting.tokens(999_600) == "1M")
        #expect(PromptCacheFormatting.tokens(1_234_567) == "1.2M")
        #expect(PromptCacheFormatting.tokens(2_000_000) == "2M")
    }

    @Test func duration_roundsDownToTheLargestUnit() {
        let style = Duration.UnitsFormatStyle.units(
            allowed: [.days, .hours, .minutes, .seconds],
            width: .narrow,
            maximumUnitCount: 1
        )
        #expect(PromptCacheFormatting.duration(299) == Duration.seconds(240).formatted(style))
        #expect(PromptCacheFormatting.duration(45) == Duration.seconds(45).formatted(style))
        #expect(PromptCacheFormatting.duration(7199) == Duration.seconds(3600).formatted(style))
        #expect(PromptCacheFormatting.duration(-5) == Duration.seconds(0).formatted(style))
    }
}

// MARK: - Decoding

struct PromptCacheDecodingTests {
    private func badge(cacheWindow: String?) throws -> AgentBadge {
        let field = cacheWindow.map { ",\"cacheWindow\":\($0)" } ?? ""
        let json = """
        {"state":"finished","updatedAt":"2026-10-07T12:05:00Z"\(field)}
        """
        return try JSONDecoder().decode(AgentProjectedBadge.self, from: Data(json.utf8)).asAgentBadge
    }

    @Test func projectedBadge_withWindow_carriesIt() throws {
        let decoded = try badge(cacheWindow: """
        {"observedAt":"2026-10-07T12:00:00Z","ttlSeconds":3600,"rewriteTokens":573000,"precision":"estimated"}
        """)
        let window = try #require(decoded.cacheWindow)
        #expect(window.ttlSeconds == 3600)
        #expect(window.rewriteTokens == 573_000)
        #expect(window.precision == .estimated)
        #expect(window.expiresAt == AgentDateParsing.parseISO8601("2026-10-07T13:00:00Z"))
    }

    @Test func projectedBadge_withoutOrWithUnreadableWindow_stillDecodes() throws {
        #expect(try badge(cacheWindow: nil).cacheWindow == nil)
        #expect(try badge(cacheWindow: "\"soon\"").cacheWindow == nil)
        #expect(try badge(cacheWindow: "{\"ttlSeconds\":3600}").cacheWindow == nil)
        let future = try badge(cacheWindow: """
        {"observedAt":"2026-10-07T12:00:00Z","ttlSeconds":300,"precision":"measured"}
        """)
        #expect(future.cacheWindow?.precision == .unknown)
        #expect(future.cacheWindow?.rewriteTokens == nil)
    }

    @Test func persistedBadge_roundTripsAndOlderBadgesDecode() throws {
        let window = AgentCacheWindow(
            observedAt: Date(timeIntervalSince1970: 1_000_000),
            ttlSeconds: 3600,
            rewriteTokens: 1200,
            precision: .estimated
        )
        let original = AgentBadge(state: .finished, updatedAt: Date(timeIntervalSince1970: 1_000_100), cacheWindow: window)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(AgentBadge.self, from: data) == original)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "cacheWindow")
        let older = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(AgentBadge.self, from: older).cacheWindow == nil)
    }
}

// MARK: - Monitor

@MainActor
struct PromptCacheMonitorTests {
    private let anchor = Date(timeIntervalSince1970: 2_000_000)

    private func window(observedAt: Date) -> AgentCacheWindow {
        AgentCacheWindow(observedAt: observedAt, ttlSeconds: 3600, rewriteTokens: 10, precision: .estimated)
    }

    @Test func update_aimsTheTimerAtTheSoonestTransition() {
        var clock = anchor
        let monitor = PromptCacheMonitor(clock: { clock })
        monitor.update(windows: [
            "claude:A": window(observedAt: anchor),
            "claude:B": window(observedAt: anchor.addingTimeInterval(-3400))
        ])
        #expect(monitor.nextFire == anchor.addingTimeInterval(200))

        clock = anchor.addingTimeInterval(201)
        monitor.advance()
        #expect(monitor.now == clock)
        #expect(monitor.nextFire == anchor.addingTimeInterval(3300))

        monitor.update(windows: [:])
        #expect(monitor.nextFire == nil)
    }

    @Test func answerAndPresentation_holdForTheSameWindowAndLapseForALaterOne() {
        let now = anchor
        let monitor = PromptCacheMonitor(clock: { now })
        let first = window(observedAt: now.addingTimeInterval(-4000))
        monitor.update(windows: ["claude:A": first])
        monitor.markAnswered(runtimeID: "claude:A", window: first)
        monitor.markPresented(runtimeID: "claude:A", window: first)
        #expect(monitor.isAnswered(runtimeID: "claude:A", window: first))
        #expect(monitor.hasPresented(runtimeID: "claude:A", window: first))

        let later = window(observedAt: now.addingTimeInterval(-3700))
        monitor.update(windows: ["claude:A": later])
        #expect(!monitor.isAnswered(runtimeID: "claude:A", window: later))
        #expect(!monitor.hasPresented(runtimeID: "claude:A", window: later))
        #expect(monitor.answeredExpiries.isEmpty, "answers for windows that are gone are pruned")
        #expect(monitor.presentedExpiries.isEmpty, "so is what was shown for them")
    }
}

/// Records what the panel typed instead of reaching a terminal.
@MainActor
private final class RecordingTypist: AgentCommandTyping {
    var typed: [String] = []
    var isAvailable = true
    var foregroundProcessName: String? = "claude"
    var foregroundProcessID: pid_t?
    var lastKeyInputAt: Date?
    var hasUnsubmittedInput = false

    func typeAgentCommand(_ command: String) -> Bool {
        guard isAvailable else { return false }
        typed.append(command)
        return true
    }
}

@MainActor
struct PromptCacheAttentionTests {
    /// A window's content, in the coordinates the test clocks report in.
    static let windowBounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func publish(
        _ attention: AttentionState,
        paneID: UUID,
        state: AgentState,
        window: AgentCacheWindow?,
        runID: String = "run",
        tmuxActive: Bool? = nil,
        isTmuxHosted: Bool? = nil,
        processID: pid_t? = nil
    ) {
        let tmux = tmuxActive.map { isActive in
            TmuxPaneLocation(
                socketPath: "/tmp/tmux-test/default",
                serverPID: "1",
                serverStartedAt: "1",
                sessionID: "$1",
                windowID: "@1",
                paneID: "%\(runID)",
                isActive: isActive
            )
        }
        var badge = AgentBadge(state: state, updatedAt: Date(), cacheWindow: window)
        badge.isTmuxHosted = isTmuxHosted ?? tmuxActive.map { _ in true }
        let runtime = AgentRuntimePresentation(
            kind: .claude,
            runID: runID,
            revision: 1,
            badge: badge,
            paneIDs: [paneID],
            tmuxLocations: tmux.map { [paneID: $0] } ?? [:],
            stateEpisodeToken: "1",
            processID: processID
        )
        let others = (attention.runtimesByKind[.claude] ?? []).filter { $0.runID != runID }
        attention.replaceRuntimes(others + [runtime], kind: .claude)
    }

    private func window(minutesAgo: Double, ttl: Int = 3600) -> AgentCacheWindow {
        AgentCacheWindow(
            observedAt: Date().addingTimeInterval(-minutesAgo * 60),
            ttlSeconds: ttl,
            rewriteTokens: 573_000,
            precision: .estimated
        )
    }

    @Test func tabMark_showsTheMostUrgentRunAndNothingWhileValid() {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 10))
        #expect(attention.promptCacheMark(in: tab) == nil, "a healthy window shows nothing")

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 57))
        #expect(attention.promptCacheMark(in: tab)?.status == .expiringSoon)

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), runID: "other")
        #expect(attention.promptCacheMark(in: tab)?.status == .expired)
        #expect(attention.promptCacheMark(runtimeID: "claude:run", paneID: paneID)?.status == .expiringSoon)
    }

    @Test func typeableExpiry_onlyForAnExpiredWindowAtThePrompt() {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        #expect(attention.expiredPromptCache(paneID: paneID) != nil)

        publish(attention, paneID: paneID, state: .running, window: window(minutesAgo: 70))
        #expect(attention.expiredPromptCache(paneID: paneID) == nil, "a running turn warms the cache")

        publish(attention, paneID: paneID, state: .needsInput, window: window(minutesAgo: 70))
        #expect(attention.expiredPromptCache(paneID: paneID) == nil, "a pending question must not get typed into")

        publish(attention, paneID: paneID, state: .idle, window: window(minutesAgo: 58))
        #expect(attention.expiredPromptCache(paneID: paneID) == nil, "expiring is not expired")
    }

    @Test func summarize_typesCompactAndAnswersThatWindowOnly() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        let first = window(minutesAgo: 70)
        publish(attention, paneID: paneID, state: .finished, window: first)
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))

        #expect(attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed == ["/compact"])
        #expect(attention.expiredPromptCache(paneID: paneID) == nil)

        // A later expiry asks again.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 65))
        #expect(attention.expiredPromptCache(paneID: paneID) != nil)
    }

    @Test func newConversation_typesClear() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .idle, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.performPromptCacheAction(.newConversation, for: expired, typist: typist))
        #expect(typist.typed == ["/clear"])
    }

    @Test func continueAsIs_answersWithoutTyping() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.performPromptCacheAction(.continueAsIs, for: expired, typist: typist))
        #expect(typist.typed.isEmpty)
        #expect(attention.expiredPromptCache(paneID: paneID) == nil)
    }

    @Test func continueAsIs_clearsTheMarksForThatWindowOnly() throws {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.promptCacheMark(in: tab)?.status == .expired)

        #expect(attention.performPromptCacheAction(.continueAsIs, for: expired, typist: RecordingTypist()))
        #expect(attention.promptCacheMark(in: tab) == nil, "an answered expiry leaves no mark")
        #expect(attention.promptCacheMark(runtimeID: "claude:run", paneID: paneID) == nil)

        // The next turn's window marks again, first as expiring.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 57))
        #expect(attention.promptCacheMark(in: tab)?.status == .expiringSoon)
    }

    @Test func secondActivation_ofTheSameAnswer_typesNothing() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        // A double click, or a click while the panel fades out, before the
        // hooks report the command.
        #expect(!attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed == ["/compact"])
    }

    @Test func commands_areTypedOnlyIntoTheAgentInFront() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))

        // The agent was suspended or killed without ending its session, and
        // the shell is in front again.
        typist.foregroundProcessName = "zsh"
        #expect(!attention.performPromptCacheAction(.newConversation, for: expired, typist: typist))
        typist.foregroundProcessName = nil
        #expect(!attention.performPromptCacheAction(.newConversation, for: expired, typist: typist))
        #expect(typist.typed.isEmpty)
        #expect(attention.expiredPromptCache(paneID: paneID) != nil, "the clock stays for another try")

        typist.foregroundProcessName = "claude"
        #expect(attention.performPromptCacheAction(.newConversation, for: expired, typist: typist))
        #expect(typist.typed == ["/clear"])
    }

    @Test func commands_followTheRecordedProcessOverItsName() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        // An npm install runs under the interpreter's name.
        typist.foregroundProcessName = "node"
        typist.foregroundProcessID = 4242
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), processID: 4243)
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(
            !attention.performPromptCacheAction(.summarize, for: expired, typist: typist),
            "another process named like an interpreter is not the agent"
        )

        publish(attention, paneID: paneID, state: .finished, window: expired.window, processID: 4242)
        #expect(attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed == ["/compact"])
    }

    @Test func commands_aRecordedProcessWinsOverAMatchingName() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        // Another `claude` in front, such as a second session started from
        // the shell the first one left behind.
        typist.foregroundProcessName = "claude"
        typist.foregroundProcessID = 200
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), processID: 100)
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(!attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed.isEmpty)
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        #expect(attention.promptCachePanelContent(for: target, typist: typist)?.commandBlock == .notInFront)
    }

    @Test func commands_neverJoinADraft() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)

        typist.hasUnsubmittedInput = true
        #expect(!attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(attention.promptCachePanelContent(for: target, typist: typist)?.commandBlock == .unsubmittedInput)
        #expect(typist.typed.isEmpty)
        #expect(attention.expiredPromptCache(paneID: paneID) != nil, "the clock stays for another try")
    }

    @Test func commands_neverFollowAKeyTypedAfterTheTurnEnded() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))

        // Say `/resume` was typed and its picker is open: no draft is
        // recorded once Return opened it, but the key came after the Stop.
        typist.lastKeyInputAt = Date().addingTimeInterval(1)
        #expect(!attention.performPromptCacheAction(.newConversation, for: expired, typist: typist))
        #expect(typist.typed.isEmpty)
    }

    @Test func commands_typeAtACleanPromptAndLeaveTheNextAnswerOpen() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        // The user's last key was the Return that started the turn.
        typist.lastKeyInputAt = Date().addingTimeInterval(-600)
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let first = try #require(attention.expiredPromptCache(paneID: paneID))
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        #expect(attention.promptCachePanelContent(for: target, typist: typist)?.canTypeCommands == true)
        #expect(attention.performPromptCacheAction(.summarize, for: first, typist: typist))

        // Our own command left the marks as they were, so the next expiry,
        // after the next turn, can be answered the same way.
        #expect(!typist.hasUnsubmittedInput)
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 65))
        let second = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.performPromptCacheAction(.newConversation, for: second, typist: typist))
        #expect(typist.typed == ["/compact", "/clear"])
    }

    @Test func commands_withoutATerminal_areDisabledAsNotInFront() {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        let content = attention.promptCachePanelContent(for: target, typist: nil)
        #expect(content?.commandBlock == .notInFront)
        #expect(content?.actions.contains(.continueAsIs) == true, "continuing as is needs no terminal")
    }

    @Test func autoOpen_neverHangsFromAClockOutsideTheWindow() {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = PromptCachePanelPresentation()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        // A tab row a lazy list keeps alive after scrolling it out of view.
        presentation.clockMoved(
            place: .tabRow(tabID: tab.id),
            instance: UUID(),
            anchor: CGRect(x: 40, y: -400, width: 16, height: 16)
        )
        #expect(!attention.autoOpenPromptCachePanel(
            paneID: paneID,
            in: PromptCacheAutoOpenWindow(
                tabID: tab.id,
                showsPaneHeader: false,
                isAnotherPanelOpen: false,
                bounds: Self.windowBounds
            ),
            presentation: presentation
        ))
        #expect(presentation.request == nil)
    }

    @Test func panelOpenedWhileExpiring_countsAsShownOnceItExpires() throws {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = PromptCachePanelPresentation()
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        presentation.clockMoved(
            place: .tabRow(tabID: tab.id),
            instance: UUID(),
            anchor: CGRect(x: 0, y: 0, width: 16, height: 16)
        )

        // Opened while yellow: nothing to count yet.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 57))
        attention.notePromptCachePanelShown(target)
        let expiring = try #require(attention.runtimesByKind[.claude]?.first?.badge.cacheWindow)
        #expect(!attention.promptCache.hasPresented(runtimeID: "claude:run", window: expiring))

        // Still open when it turns red: the host reports it again.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        attention.notePromptCachePanelShown(target)
        #expect(!attention.autoOpenPromptCachePanel(
            paneID: paneID,
            in: PromptCacheAutoOpenWindow(
                tabID: tab.id,
                showsPaneHeader: false,
                isAnotherPanelOpen: false,
                bounds: PromptCacheAttentionTests.windowBounds
            ),
            presentation: presentation
        ), "it was seen red, so it does not open by itself")
    }

    @Test func tmux_aRunWhoseLocationIsUnknownTakesNoCommands() {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), isTmuxHosted: true)
        #expect(attention.expiredPromptCache(paneID: paneID) == nil)
    }

    @Test func tmux_onlyTheActivePanesRunTakesTheKeys() throws {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        typist.foregroundProcessName = "tmux"

        // Out of sight in its tmux window: marked on the tab, but its
        // commands cannot be typed, since the keys would reach the run that
        // is in sight.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), tmuxActive: false)
        #expect(attention.expiredPromptCache(paneID: paneID) == nil)
        #expect(attention.promptCacheMark(in: tab)?.status == .expired)

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70), tmuxActive: true)
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))

        // The user switched tmux panes after the panel was drawn.
        publish(attention, paneID: paneID, state: .finished, window: expired.window, tmuxActive: false)
        #expect(!attention.performPromptCacheAction(.summarize, for: expired, typist: typist))

        publish(attention, paneID: paneID, state: .finished, window: expired.window, tmuxActive: true)
        #expect(attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed == ["/compact"])
    }

    @Test func actions_doNothingOnceTheRunMovedOnOrWithoutATerminal() throws {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let typist = RecordingTypist()
        let stale = window(minutesAgo: 70)
        publish(attention, paneID: paneID, state: .finished, window: stale)
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))

        // A turn started after the panel was drawn.
        publish(attention, paneID: paneID, state: .running, window: stale)
        #expect(!attention.performPromptCacheAction(.summarize, for: expired, typist: typist))
        #expect(typist.typed.isEmpty)

        // The turn finished with a new window; the old panel's answer is void.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 61))
        #expect(!attention.performPromptCacheAction(.continueAsIs, for: expired, typist: typist))

        // No terminal to type into keeps the clock up.
        let current = try #require(attention.expiredPromptCache(paneID: paneID))
        typist.isAvailable = false
        #expect(!attention.performPromptCacheAction(.summarize, for: current, typist: typist))
        #expect(attention.expiredPromptCache(paneID: paneID) != nil)
        #expect(!attention.performPromptCacheAction(.summarize, for: current, typist: nil))
    }

    // MARK: Clocks, panel, and auto-open

    @Test func paneAndTabClocks_speakForTheRunAndItsPane() {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        #expect(attention.promptCacheMark(paneID: paneID) == nil)

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expected = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        #expect(attention.promptCacheMark(paneID: paneID)?.target == expected)
        #expect(attention.promptCacheMark(in: tab)?.target == expected)
        #expect(attention.promptCacheMark(paneID: UUID()) == nil, "another pane shows no clock")
    }

    @Test func panelContent_followsTheClockAndWhetherCommandsCanBeTyped() {
        let (_, _, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 57))
        let typist = RecordingTypist()
        let soon = attention.promptCachePanelContent(for: target, typist: typist)
        #expect(soon?.status == .expiringSoon)
        #expect(soon?.actions.isEmpty == true, "an expiring cache only informs")

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = attention.promptCachePanelContent(for: target, typist: typist)
        #expect(expired?.actions == [.summarize, .newConversation, .continueAsIs])
        #expect(expired?.canTypeCommands == true)

        publish(attention, paneID: paneID, state: .needsInput, window: window(minutesAgo: 70))
        #expect(
            attention.promptCachePanelContent(for: target, typist: typist)?.commandBlock == .notAtPrompt,
            "a pending question keeps the panel but not its commands"
        )

        publish(attention, paneID: paneID, state: .running, window: window(minutesAgo: 70))
        #expect(attention.promptCachePanelContent(for: target, typist: typist) == nil, "a running turn has no clock")
    }

    @Test func autoOpen_opensOnceBelowTheClockFocusArrivedAt() throws {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = PromptCachePanelPresentation()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))

        func autoOpen(showsPaneHeader: Bool = false, isAnotherPanelOpen: Bool = false) -> Bool {
            attention.autoOpenPromptCachePanel(
                paneID: paneID,
                in: PromptCacheAutoOpenWindow(
                    tabID: tab.id,
                    showsPaneHeader: showsPaneHeader,
                    isAnotherPanelOpen: isAnotherPanelOpen,
                    bounds: PromptCacheAttentionTests.windowBounds
                ),
                presentation: presentation
            )
        }

        #expect(!autoOpen(), "no clock on screen to hang from")
        let tabRow = PromptCacheClockPlace.tabRow(tabID: tab.id)
        presentation.clockMoved(place: tabRow, instance: UUID(), anchor: CGRect(x: 40, y: 80, width: 16, height: 16))
        #expect(!autoOpen(isAnotherPanelOpen: true), "never over another floating panel")
        #expect(!autoOpen(showsPaneHeader: true), "with headers it hangs from the header clock, not drawn here")

        #expect(autoOpen())
        let request = try #require(presentation.request)
        #expect(request.place == tabRow)
        #expect(request.trigger == .automatic)
        #expect(request.target == PromptCacheTarget(runtimeID: "claude:run", paneID: paneID))

        presentation.close()
        #expect(!autoOpen(), "once per expiry")

        // The next turn's expiry may open by itself again.
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 65))
        #expect(autoOpen())
    }

    @Test func autoOpen_onlyForAnExpiryItsCommandsCanActOn() throws {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = PromptCachePanelPresentation()
        presentation.clockMoved(
            place: .paneHeader(paneID: paneID),
            instance: UUID(),
            anchor: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        func autoOpen() -> Bool {
            attention.autoOpenPromptCachePanel(
                paneID: paneID,
                in: PromptCacheAutoOpenWindow(
                    tabID: tab.id,
                    showsPaneHeader: true,
                    isAnotherPanelOpen: false,
                    bounds: PromptCacheAttentionTests.windowBounds
                ),
                presentation: presentation
            )
        }

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 57))
        #expect(!autoOpen(), "expiring soon only informs")
        publish(attention, paneID: paneID, state: .needsInput, window: window(minutesAgo: 70))
        #expect(!autoOpen(), "a pending question comes first")

        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let expired = try #require(attention.expiredPromptCache(paneID: paneID))
        #expect(attention.performPromptCacheAction(.continueAsIs, for: expired, typist: nil))
        #expect(!autoOpen(), "an answered expiry stays quiet")
    }

    @Test func panelTheUserOpened_countsAsTheOneAutoOpen() {
        let (_, tab, paneID) = WindowSessionFixture.withLooseTab()
        let attention = AttentionState()
        let presentation = PromptCachePanelPresentation()
        publish(attention, paneID: paneID, state: .finished, window: window(minutesAgo: 70))
        let place = PromptCacheClockPlace.tabRow(tabID: tab.id)
        let target = PromptCacheTarget(runtimeID: "claude:run", paneID: paneID)
        let frame = CGRect(x: 0, y: 0, width: 16, height: 16)
        presentation.clockClicked(place: place, instance: UUID(), anchor: frame, target: target)
        attention.notePromptCachePanelShown(target)
        presentation.close()

        #expect(!attention.autoOpenPromptCachePanel(
            paneID: paneID,
            in: PromptCacheAutoOpenWindow(
                tabID: tab.id,
                showsPaneHeader: false,
                isAnotherPanelOpen: false,
                bounds: PromptCacheAttentionTests.windowBounds
            ),
            presentation: presentation
        ))
    }
}
