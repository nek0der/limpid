// AgentNotificationEmitter.swift
// Limpid — raises the notification the rules asked for.
//
// The rules choose the moment, the wording under the title, and whether it
// interrupts. What is decided here is the part only this process knows: what
// the container is called, and how the entry is filed.

import Foundation

@MainActor
struct AgentNotificationEmitter {
    let kind: AgentKind
    let notificationManager: LimpidNotificationManager
    /// Background tmux panes are not visible merely because their client
    /// surface is focused. Those transitions still deserve a banner.
    var suppressWhenPaneFocused = true
    /// Nil for legacy pane-only notification producers.
    var runtimeID: String?
    /// Revision of the exact runtime event being delivered. Runtime IDs stay
    /// stable for an invocation, while this value advances for each turn.
    var eventToken: String?

    /// Raises the notification the rules decided on. What is decided here is
    /// the title, the container label, the history kind, and for a wait its
    /// words. The title says what happened ("Claude Code finished a turn") and
    /// the container label is the subtitle: both agents set a
    /// generic terminal title, so the project or worktree is what says which
    /// one it was, but a banner titled by a place alone does not say why it
    /// came.
    ///
    /// `wait` is the run's wait as its record states it
    /// (`AppState.waitOf`), so the banner names the wait the decision bar
    /// shows. The payload's body is cut to a banner's length, or stands in
    /// with the last prompt, so it is never read for which wait it is.
    /// `nil` when the run is not known here, which words the wait as one
    /// for an answer.
    ///
    /// `finished` is what a finished turn reported (`AppState.finishedTurn`),
    /// which the history keeps as values; without it, the turn is filed with
    /// the payload's words alone. `answered` is the prompt a finished turn's
    /// reply answers, when the body says the reply in its place
    /// (`AppState.finishedText`); the subtitle names it beside the place.
    func deliver(
        _ payload: AgentNotifyPayload,
        wait: PromptWait? = nil,
        finished: NotificationEvent? = nil,
        answered: String? = nil,
        tab: Tab,
        session: WorkspaceSession
    ) {
        let locale = notificationManager.appLocale()
        let title = switch payload.kind {
        case .finished: kind.finishedTitle.resolved(in: locale)
        case .needsInput: kind.waitTitle(for: wait).resolved(in: locale)
        case .failed: kind.stoppedTitle.resolved(in: locale)
        }
        let containerLabel = session.containerLabel(for: tab.container, locale: locale)
        let entryKind: NotificationEntry.Kind = switch payload.kind {
        case .finished: .agentFinished
        case .needsInput: .agentNeedsInput
        case .failed: .agentError
        }
        let body = switch wait {
        // As the session row words the wait (`PromptWaitText.line`:
        // "Waiting for approval: notes.txt", "Question: …", "Needs
        // response: …"), on one line and cut to a banner's length, rather
        // than the tool's bare name; with nothing to name, the title, not
        // the prompt that started the turn.
        case let wait?:
            Self.namesSomething(wait)
                ? Self.truncatedPrompt(PromptWaitText.line(wait).resolved(in: locale)) ?? title
                : title
        case nil:
            payload.body ?? title
        }
        // What the history words the row from: the same wait, receipt, or
        // reason the banner says, as values.
        let event: NotificationEvent = switch payload.kind {
        case .finished: finished ?? .finished(agent: kind, turn: nil, head: payload.body)
        // A run not known here: its words, read as a wait from before the
        // record said which.
        case .needsInput: .waiting(wait ?? PromptWait(detail: payload.body), agent: kind)
        case .failed: .stopped(agent: kind, reason: payload.body)
        }
        send(
            Delivery(
                title: title,
                subtitle: Self.subtitle(forContainerLabel: containerLabel, answered: answered, locale: locale),
                body: body,
                kind: entryKind,
                event: event,
                presentsBanner: payload.presentsBanner
            ),
            tab: tab,
            paneID: payload.pane,
            session: session,
            locale: locale
        )
    }

    /// The banner's subtitle: where the agent works, or none for a label
    /// with nothing in it.
    nonisolated static func subtitle(forContainerLabel label: String) -> String? {
        label.isEmpty ? nil : label
    }

    /// The subtitle of a banner whose body says a reply: the place, then
    /// the prompt the reply answers, which the body no longer quotes. Any
    /// other banner's is the place alone.
    nonisolated static func subtitle(forContainerLabel label: String, answered: String?, locale: Locale) -> String? {
        guard let answered else { return subtitle(forContainerLabel: label) }
        return AgentStatusText.joined([label, answered], locale: locale)
    }

    /// What one transition hands to the notification manager. Bundled
    /// so the per-state emitters differ only in how they fill it in.
    private struct Delivery {
        let title: String
        let subtitle: String?
        let body: String
        let kind: NotificationEntry.Kind
        let event: NotificationEvent
        var presentsBanner = true
    }

    private func send(
        _ delivery: Delivery,
        tab: Tab,
        paneID: UUID,
        session: WorkspaceSession,
        locale: Locale
    ) {
        notificationManager.send(
            title: delivery.title,
            subtitle: delivery.subtitle,
            body: delivery.body,
            paneID: paneID,
            tabID: tab.id,
            containerID: tab.container,
            requireFocus: suppressWhenPaneFocused,
            kind: delivery.kind,
            tabTitleSnapshot: tab.displayTitle,
            containerLabel: session.containerLabel(for: tab.container, locale: locale),
            runtimeID: runtimeID,
            eventToken: eventToken,
            event: delivery.event,
            presentsBanner: delivery.presentsBanner
        )
        // Agent events fire the macOS banner + history entry (above) but
        // deliberately do NOT bump the per-pane unread count that drives
        // the tab's dot — an agent's attention surface is its state glyph
        // and the Needs Attention list, not the dot. Routing them through
        // the dot too would double-signal the same event. The dot is
        // reserved for non-agent unread (terminal OSC 9/777, child-exit)
        // handled in GhosttyEventCoordinator.
    }

    /// Whether the wait names what it is about (a command, a file, a tool,
    /// the agent's words), which the title alone does not say.
    private static func namesSomething(_ wait: PromptWait) -> Bool {
        switch wait {
        case let .approval(approval): approval.fact != nil
        case let .question(detail), let .unclassified(detail): detail != nil
        }
    }

    /// Collapse whitespace + truncate to ~80 chars. Returns `nil` if
    /// the result would be empty so callers can fall back to a generic
    /// string. The macOS banner only shows a few lines anyway, so an
    /// 80-char window matches what the user actually sees.
    private static func truncatedPrompt(_ raw: String) -> String? {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        let limit = 80
        if collapsed.count <= limit {
            return collapsed
        }
        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: limit - 1)
        return collapsed[..<cutoff] + "…"
    }
}

extension AgentKind {
    /// macOS notification title used when a `(running|compacting) →
    /// finished` transition fires. The provider names itself through the
    /// registry, so adding one adds no string here; only the sentence around
    /// the name is translated.
    var finishedTitle: LocalizedStringResource {
        let name = AgentProviderRegistry.displayName(for: self)
        return LocalizedStringResource("\(name) finished a turn", comment: "Notification title; the agent's name")
    }

    /// macOS notification title used when a pane starts to wait on the
    /// person, in the words the rows use for the wait (`PromptWait`): an
    /// approval, a question, or a response we cannot name (also when the
    /// wait is not known here).
    func waitTitle(for wait: PromptWait?) -> LocalizedStringResource {
        let name = AgentProviderRegistry.displayName(for: self)
        return switch wait {
        case .approval?:
            LocalizedStringResource("\(name) is waiting for approval", comment: "Notification title; the agent's name")
        case .question?:
            LocalizedStringResource("\(name) is asking a question", comment: "Notification title; the agent's name")
        case .unclassified?, nil:
            LocalizedStringResource("\(name) is waiting for a response", comment: "Notification title; the agent's name")
        }
    }

    /// History-row title used when a pane transitions into `.error`
    /// and there is no container label to anchor on. The screen calls
    /// every error a stop.
    var stoppedTitle: LocalizedStringResource {
        let name = AgentProviderRegistry.displayName(for: self)
        return LocalizedStringResource("\(name) stopped", comment: "History row title; the agent's name")
    }
}
