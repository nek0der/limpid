// AppState+NotificationRouting.swift
// Limpid — where notifications lead, and keeping their banners true to the attention list.

import AppKit
import Foundation

extension AppState {
    /// The sync that announces when a usage limit lifts, reading the
    /// limits from the attention list and the switch from Settings.
    static func makeUsageLimitResetSync(
        _ attentionQueue: AttentionQueueStore,
        _ settingsStore: SettingsStore,
        _ notificationManager: LimpidNotificationManager
    ) -> UsageLimitResetSync {
        UsageLimitResetSync(
            limits: { [attentionQueue] in UsageLimits(items: attentionQueue.queue.items) },
            isEnabled: { [settingsStore] in settingsStore.settings.general.notifyOnUsageLimitReset },
            schedule: { [notificationManager] in notificationManager.scheduleUsageLimitReset(for: $0, at: $1) },
            cancel: { [notificationManager] in notificationManager.cancelUsageLimitReset(for: $0) }
        )
    }

    /// Opens what a notification or its history row points at
    /// (`NotificationRoute`): in the window that shows its project, brought
    /// forward and back if hidden, else in the window the person
    /// was last in, brought back if hidden and switched to the project in
    /// place; what belongs to no project opens there as it is. What it
    /// names is in front of the window's review tab, as ⌘J puts it
    /// (`reviewTargetMove`). False when nothing it named is left.
    @discardableResult
    func openNotificationTarget(_ target: NotificationTarget) -> Bool {
        let window = windowRegistry.backgroundCommandTarget
        // `nil` only for a project gone since the route was read.
        let inProject = { (projectID: UUID?) in
            self.windowRegistry.present(project: projectID, in: self.session, from: window)
        }
        switch NotificationRoute.first(for: target, facts: notificationFacts) {
        case let .card(key):
            // The window and pane stay as they are; a hidden one comes
            // back to show the card.
            guard let approval = approvalPresentation.ledger.entries[key]?.presentation else { return false }
            windowRegistry.bringBack(window).approvalCard.present(approval, from: approvalPresentation)
        case let .runtime(runtimeID):
            attentionQueue.focus(runtimeID: runtimeID, from: window)
        case let .pane(paneID):
            guard let shown = inProject(session.tab(containing: paneID)?.container.projectID) else { return false }
            reviewTargetMove.toPane(paneID, in: shown)
        case let .tab(tabID):
            guard let shown = inProject(session.tab(tabID)?.container.projectID) else { return false }
            reviewTargetMove.toTab(tabID, in: shown)
        case let .container(containerID):
            guard let shown = inProject(containerID.projectID) else { return false }
            reviewTargetMove.toContainer(containerID, in: shown)
        case nil:
            return false
        }
        return true
    }

    /// Whether a notification or history row still leads anywhere: what the
    /// history panel grays out when it does not.
    func canOpenNotificationTarget(_ target: NotificationTarget) -> Bool {
        NotificationRoute.first(for: target, facts: notificationFacts) != nil
    }

    private var notificationFacts: NotificationRoute.Facts {
        NotificationRoute.Facts(
            opensCard: { [approvalPresentation] in approvalPresentation.opensCard($0) },
            isRuntimeShown: { [weak self] in self?.runtimeLocation($0) != nil },
            isPaneAlive: { [session] in session.tab(containing: $0) != nil },
            isTabAlive: { [session] in session.tab($0) != nil },
            isContainerAlive: { [session] in session.containerExists($0) }
        )
    }

    /// The tab and pane a runtime is shown in now (`AttentionState.shownPane`),
    /// or `nil` when it runs in no pane that is in a tab. What both a
    /// notification's route and going to the runtime read.
    func runtimeLocation(_ runtimeID: String) -> (tabID: UUID, paneID: UUID)? {
        guard let runtime = attention.allRuntimes.first(where: { $0.id == runtimeID }),
              let paneID = AttentionState.shownPane(of: runtime, in: session),
              let tab = session.tab(containing: paneID)
        else { return nil }
        return (tab.id, paneID)
    }

    /// Keeps the agents' banners in step with the attention list: shown
    /// only while their source is out of sight, gathered into one after the
    /// Mac wakes, and taken back once they cannot be acted on from.
    func startNotificationRouting() {
        LimpidNotificationDelegate.isSourceSeen = { [weak self] paneID, runtimeID in
            self?.isNotificationSourceSeen(paneID: paneID, runtimeID: runtimeID) ?? false
        }
        // Whatever the agents report while the Mac slept arrives at once on
        // wake; one banner says how much is waiting instead of a burst.
        let center = NSWorkspace.shared.notificationCenter
        wakeObservation = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                notificationManager.holdAgentBanners(for: Self.wakeBannerHold) { [weak self] in
                    guard let self else { return nil }
                    return AttentionSummaryText.make(attentionQueue.queue.counts(), locale: notificationManager.appLocale())
                }
            }
        }
        observeRepeatedly { [weak self] in
            _ = self?.approvalPresentation.ledger.entries
        } onChange: { [weak self] in
            self?.withdrawStaleRequestBanners()
        }
        observeRepeatedly { [weak self] in
            _ = self?.attentionQueue.hasItems
        } onChange: { [weak self] in
            guard let self, !attentionQueue.hasItems else { return }
            notificationManager.removeSummaryBanner()
        }
    }

    /// How long after waking the agents' banners are gathered: long enough
    /// for the hooks that queued up during sleep to land.
    static let wakeBannerHold: Duration = .seconds(8)

    /// Whether the person can see where an agent's notification came from:
    /// any pane its runtime shows in (a tmux session attached in several,
    /// counting only the one whose tmux pane is in front), or else the pane
    /// the banner names.
    private func isNotificationSourceSeen(paneID: UUID?, runtimeID: String?) -> Bool {
        let visibility = windowRegistry.attention
        if let runtimeID, let runtime = attention.allRuntimes.first(where: { $0.id == runtimeID }), !runtime.paneIDs.isEmpty {
            return runtime.activeAttachmentPaneIDs.contains(where: visibility.isSeen)
        }
        return paneID.map(visibility.isSeen) ?? false
    }

    /// Posts the banner of a request that just arrived (`AttentionEffect
    /// .notify`), carrying the request, so opening it opens the card while
    /// the request can be answered there. None while the request's pane is
    /// in sight: its own prompt, or its card, is in front of the person.
    func postRequestBanner(for id: AttentionItemID) {
        guard let item = attentionQueue.queue.items.first(where: { $0.id == id }) else { return }
        let fact: ApprovalFact
        switch item.kind {
        case let .approval(requestFact), let .question(requestFact): fact = requestFact
        case .prompt, .stop, .unread: return
        }
        guard let approval = approvalPresentation.ledger.entries[fact.key]?.presentation else { return }
        var runtimeID: String?
        var paneID: UUID?
        if case let .runtime(id, _, pane, _, _) = item.subject {
            runtimeID = id
            paneID = pane
        }
        guard !isNotificationSourceSeen(paneID: paneID, runtimeID: runtimeID) else { return }
        let tab = paneID.flatMap { session.tab(containing: $0) }
        let locale = notificationManager.appLocale()
        let containerLabel = tab.map { session.containerLabel(for: $0.container, locale: locale) }
        let text = RequestBannerText.make(for: approval, containerLabel: containerLabel, locale: locale)
        // The hook's wait may have been announced first (a question's
        // does); the request's banner stands for it now. Its history row
        // stays: it records when the agent started waiting.
        if let runtimeID {
            notificationManager.removeRuntimeBanner(runtimeID)
        }
        notificationManager.send(
            title: text.title,
            subtitle: text.subtitle,
            body: text.body,
            paneID: paneID,
            tabID: tab?.id,
            containerID: tab?.container,
            // Seen-ness was decided above, by what the person can see.
            requireFocus: false,
            kind: .agentNeedsInput,
            tabTitleSnapshot: tab?.displayTitle,
            containerLabel: containerLabel.flatMap { $0.isEmpty ? nil : $0 },
            runtimeID: runtimeID,
            requestKey: fact.key,
            event: RequestBannerText.event(for: approval)
        )
        announcedRequestKeys.insert(fact.key)
    }

    /// Takes back the banner of each announced request that can no longer
    /// be acted on from it (`ApprovalRequestState.keepsBanner`), or that
    /// left the ledger, so Notification Center does not keep offering an
    /// answer that cannot be given.
    private func withdrawStaleRequestBanners() {
        let entries = approvalPresentation.ledger.entries
        for key in announcedRequestKeys where entries[key]?.state.keepsBanner != true {
            notificationManager.removeBanner(for: key)
            announcedRequestKeys.remove(key)
        }
    }
}
