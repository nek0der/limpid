// NewWorktreeSheetHost.swift
// Weir — the new worktree sheet, held at the window's root so it opens whatever the window shows, and ⌥⌘N.

import AppKit
import os
import SwiftUI

private let log = Logger.weir("supervision.new-worktree")

extension View {
    /// The window's new worktree sheet and ⌥⌘N, for the root of the
    /// supervision window. At the root rather than on the session's body,
    /// so a header's ＋ in a window that shows no project opens its sheet
    /// too: on the body, the request waited unseen, refused every
    /// later one, and opened once a project was shown. ⌥⌘N works on the
    /// window's project, so it does nothing in a window that shows none.
    func hostsNewWorktreeSheet(state: AppState) -> some View {
        modifier(NewWorktreeSheetHost(state: state))
    }
}

private struct NewWorktreeSheetHost: ViewModifier {
    let state: AppState
    @Environment(ProjectWindowState.self) private var window
    @Environment(SessionLaunchStore.self) private var launches
    @Environment(\.weirAccent) private var weirAccent
    @Environment(\.locale) private var locale

    private var session: WorkspaceSession {
        state.session
    }

    func body(content: Content) -> some View {
        content
            .onWindowCommand(of: window, takeCommand)
            .sheet(item: Binding(
                get: { window.newWorktreeSheet.request },
                set: { request in
                    if request == nil {
                        window.newWorktreeSheet.close()
                    }
                }
            )) { request in
                VStack(spacing: 0) {
                    if window.newWorktreeSheet.introducesInstantKey {
                        InstantWorktreeKeyNote(keyboard: state.settingsStore.settings.keyboard)
                    }
                    NewSessionSheet(request: request)
                }
                .environment(session)
                .environment(window)
                .environment(launches)
                .environment(state.attention)
                .environment(\.locale, locale)
                .weirAccentPropagated(weirAccent)
                .onAppear { sheetAppeared(request) }
            }
            // A request still waiting as the window's other sheets end lost
            // its moment, and is dropped rather than opened unasked
            // (`NewWorktreeSheetSlot.coverEnded`).
            .onChange(of: window.hasAttachedSheet) { wasCovered, isCovered in
                if wasCovered, !isCovered {
                    window.newWorktreeSheet.coverEnded()
                }
            }
            // Created or canceled, the keys go back to the focused pane; a
            // session that starts later takes them as its own pane mounts.
            .returnsKeyboardOnDismiss(
                isPresented: window.newWorktreeSheet.request != nil,
                window: window.id,
                session: session,
                registry: state.registry
            )
    }

    private func takeCommand(_ command: WindowCommand) -> Bool {
        guard command == .newWorktreeNow else { return false }
        if !SupervisionWindowActions.introduceInstantWorktree(in: window, keyboard: state.settingsStore.settings.keyboard) {
            createWorktreeAtOnce()
        }
        return true
    }

    /// The sheet is up: what it says of ⌥⌘N is said, and not again.
    private func sheetAppeared(_ request: NewSessionSheetRequest) {
        if window.newWorktreeSheet.appeared(request.id) {
            state.settingsStore.settings.keyboard.markIntroduced(.newWorktreeNow)
        }
    }

    /// ⌥⌘N: the worktree made with no sheet (`NewSessionActions.createAtOnce`),
    /// said to VoiceOver as it starts and once made, since nothing on
    /// screen changes until the row is there, in a sidebar the keys are
    /// not in. A second ⌥⌘N while it works does nothing, and so does one in
    /// a window that shows no project.
    private func createWorktreeAtOnce() {
        guard !window.isCreatingWorktreeAtOnce, window.selection.shownProjectID != nil else { return }
        let stores = NewSessionStores(session: session, launches: launches, settingsStore: state.settingsStore)
        let locale = locale
        AccessibilityNotification.Announcement(LocalizedStringResource(
            "Creating the worktree…",
            comment: "New worktree sheet: git is adding the worktree"
        ).resolved(in: locale)).post()
        Task {
            switch await NewSessionActions.createAtOnce(in: window, stores: stores) {
            case let .created(branch):
                AccessibilityNotification.Announcement(InstantWorktreePlan.announcement(branch: branch).resolved(in: locale)).post()
            case let .failedUnshown(message):
                // The sheet that says why could not come up; said here so
                // the failure is not lost, and beeped for those not
                // listening.
                let text = message.resolved(in: locale)
                log.notice("⌥⌘N failed with its sheet refused: \(text, privacy: .private)")
                NSSound.beep()
                AccessibilityNotification.Announcement(text).post()
            case .openedSheet, .nothing:
                break
            }
        }
    }
}

/// Above the form, the one time ⌥⌘N opens the sheet after an update: what
/// those keys do from now on, and where the sheet is.
private struct InstantWorktreeKeyNote: View {
    let keyboard: KeyboardSettings

    var body: some View {
        Label {
            Text(verbatim: InstantWorktreeKeyText.note(
                now: keyboard.shortcut(for: .newWorktreeNow),
                sheet: keyboard.shortcut(for: .newWorktree)
            ).resolved(in: locale))
        } icon: {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
        }
        .font(.supervision(.caption))
        .foregroundStyle(SupervisionTokens.muted.color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WeirLayout.Supervision.newSessionSheetInsets.leading)
        .padding(.top, WeirLayout.Supervision.newSessionSheetInsets.top)
        .frame(width: WeirLayout.Supervision.newSessionSheetWidth)
        .accessibilityElement(children: .combine)
    }

    @Environment(\.locale) private var locale
}
