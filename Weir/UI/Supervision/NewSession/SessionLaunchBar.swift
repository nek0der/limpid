// SessionLaunchBar.swift
// Weir — the line under a new worktree's terminal from its copy to its agent's start, a failed stage, and notes.

import SwiftUI

/// What a new worktree's row shows between its making and what it opens,
/// in the decision bar's place: the files being copied, the setup
/// step that runs, the agent starting or waiting in its terminal, or the
/// stage that failed, what to do, the end of its log, and the way on. What
/// went short without stopping it (the fetch, a file not copied) is said
/// under it, and stays once everything ran, until dismissed. Once its
/// agent reports its start, the row has the agent's own decision bar.
struct SessionLaunchBar: View {
    let launch: SessionLaunch
    @Environment(WorkspaceSession.self) private var session
    @Environment(SessionLaunchStore.self) private var launches
    /// The window the bar is drawn in, whose tab it brings forward.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale

    var body: some View {
        SessionLaunchBarLayout(
            tag: tagText,
            isFailed: launch.failure != nil,
            isInProgress: isInProgress,
            headline: headline,
            // A failed stage's headline is the stage's name alone; the tag
            // says it stopped.
            spokenHeadline: launch.failure == nil ? headline : LocalizedStringResource(
                "\(tagText), \(headline)",
                comment: "Two facts spoken in a row: a failed stage's tag and name, the menu bar item's count and its kinds"
            ).resolved(in: locale),
            detail: detail,
            logTail: launch.failure?.logTail
        ) {
            actions
        }
    }

    /// Whether the log shows whole: a few short lines.
    static func isShort(_ tail: String) -> Bool {
        let lines = tail.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.count <= 6 && lines.allSatisfy { $0.count <= 160 }
    }

    private var isInProgress: Bool {
        switch launch.phase {
        case .copyingFiles, .settingUp, .starting(isLaunched: true): true
        case .starting(isLaunched: false): isAgentTabInFront
        case .waitingInTerminal, .done, .failed: false
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch launch.phase {
        case .copyingFiles, .starting(isLaunched: true):
            EmptyView()
        case .settingUp:
            if !launch.isStoppingSetup {
                skipButton
            }
        case .starting(isLaunched: false):
            showTabButton
        case .waitingInTerminal:
            showTabButton
            dismissButton
        case .done:
            dismissButton
        case let .failed(failure):
            Button {
                launches.retry(worktreeID: launch.worktreeID, in: session, window: window.id)
            } label: {
                Text(LocalizedStringResource(
                    "newSession.retry",
                    defaultValue: "Retry",
                    comment: "New worktree's failed stage: runs it again"
                ))
            }
            .buttonStyle(SupervisionPrimaryButtonStyle())
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
            if case .setup = failure.stage {
                skipButton
            }
        }
    }

    private var dismissButton: some View {
        Button {
            launches.dismiss(worktreeID: launch.worktreeID)
        } label: {
            Text("Dismiss")
        }
        .buttonStyle(.supervisionSecondary)
        // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
        .focusable(false)
    }

    private var skipButton: some View {
        Button {
            launches.skipSetup(worktreeID: launch.worktreeID, in: session, window: window.id)
        } label: {
            if launch.request.open == .nothing {
                Text("Skip Setup", comment: "New worktree: stops the project's setup commands; nothing opens after them")
            } else {
                Text(
                    "Skip Setup and Open",
                    comment: "New worktree: opens what was asked for without the rest of the project's setup commands"
                )
            }
        }
        .buttonStyle(.supervisionSecondary)
        // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
        .focusable(false)
    }

    /// The agent's tab, brought to front: its terminal, and so its agent,
    /// starts when it is first shown. Not drawn while it is in front.
    @ViewBuilder
    private var showTabButton: some View {
        if let paneID = launch.paneID, let tab = session.tab(containing: paneID), !isAgentTabInFront {
            Button {
                session.setActiveTab(tab.id, in: window.id, intent: .person)
            } label: {
                Text("Show")
            }
            .buttonStyle(SupervisionPrimaryButtonStyle())
            // Out of the ⇥ order, so ⇥ stays the terminal's for its TUI.
            .focusable(false)
        }
    }

    private var isAgentTabInFront: Bool {
        guard let paneID = launch.paneID, let tab = session.tab(containing: paneID) else { return false }
        return window.selection.activeTabID == tab.id
    }

    private var agentName: String {
        launch.request.agent.map { AgentProviderRegistry.displayName(for: $0) } ?? ""
    }

    private var tagText: String {
        switch launch.phase {
        case .copyingFiles:
            LocalizedStringResource("Copy", comment: "New worktree: tag while the files Git ignores are copied in").resolved(in: locale)
        case .settingUp:
            LocalizedStringResource("Setup", comment: "New worktree: tag while the project's setup commands run").resolved(in: locale)
        case .starting, .waitingInTerminal:
            LocalizedStringResource("Starting", comment: "New worktree: tag while its agent starts").resolved(in: locale)
        case .done:
            LocalizedStringResource("Note", comment: "New worktree: tag of what went short while it was made").resolved(in: locale)
        case .failed:
            LocalizedStringResource("Stopped").resolved(in: locale)
        }
    }

    private var headline: String {
        switch launch.phase {
        case .copyingFiles:
            LocalizedStringResource("Copying files…", comment: "New worktree: the files Git ignores are being copied in")
                .resolved(in: locale)
        case let .settingUp(stepIndex, stepCount, command):
            LocalizedStringResource(
                "Running setup command \(stepIndex + 1) of \(stepCount): \(command)",
                comment: "New worktree: the setup command that runs; the numbers count from 1, the last argument is the command"
            ).resolved(in: locale)
        case .starting(isLaunched: true):
            LocalizedStringResource("Starting \(agentName)…", comment: "New worktree: its agent is starting; the agent's name")
                .resolved(in: locale)
        case .starting(isLaunched: false) where isAgentTabInFront:
            // In front, its terminal is being made.
            LocalizedStringResource("Starting \(agentName)…", comment: "New worktree: its agent is starting; the agent's name")
                .resolved(in: locale)
        case .starting(isLaunched: false):
            LocalizedStringResource(
                "\(agentName) starts when its tab is opened.",
                comment: "New worktree: the agent's tab opened behind another; the agent's name"
            ).resolved(in: locale)
        case .waitingInTerminal:
            LocalizedStringResource(
                "\(agentName) is running but hasn’t reported to Weir.",
                comment: "New worktree: the agent runs in its terminal and has not reported its start; the agent's name"
            ).resolved(in: locale)
        case .done:
            notes.first ?? ""
        case let .failed(failure):
            Self.stageName(failure.stage).resolved(in: locale)
        }
    }

    /// The notes as said, one a line: under the headline while the launch
    /// runs, and the rest after the first, which is the headline, once done.
    private var detail: String? {
        let lines: [String] = switch launch.phase {
        case .copyingFiles, .settingUp, .starting:
            notes
        case .done:
            Array(notes.dropFirst())
        case .waitingInTerminal:
            [LocalizedStringResource(
                // swiftlint:disable:next line_length
                "If its terminal asks something, such as to sign in or to trust this folder, answer it there. Weir can’t follow an agent started by its full path, such as through an alias.",
                comment: "New worktree: what to do while the agent waits in its terminal"
            ).resolved(in: locale)] + notes
        case let .failed(failure):
            [failure.message.resolved(in: locale)] + notes
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private var notes: [String] {
        launch.notes.map { Self.noteText($0).resolved(in: locale) }
    }

    /// What a note says.
    static func noteText(_ note: SessionLaunch.Note) -> LocalizedStringResource {
        switch note {
        case let .fetch(shortfall):
            return NewSessionModel.shortfallText(shortfall)
        case .ignoredFilesNotListed:
            return LocalizedStringResource(
                "Couldn’t list the files Git ignores, so none were copied.",
                comment: "New worktree: git could not list the ignored files the copy picks from, so nothing was copied in"
            )
        case let .copyFailed(paths):
            // The list is formatted when the resource is resolved, so it
            // joins in that language's way (「、」 in Japanese, not ", ").
            return LocalizedStringResource(
                "Couldn’t copy \(paths, format: .list(type: .and, width: .narrow)).",
                comment: "New worktree: files Git ignores that could not be copied in; the argument lists their paths"
            )
        case let .copySkippedOverLimit(paths, limit):
            let size = ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
            return LocalizedStringResource(
                "Didn’t copy \(paths, format: .list(type: .and, width: .narrow)): the files would come to more than \(size).",
                comment: "New worktree: files Git ignores left out at the copy's limit; their paths, then the limit, as in 256 MB"
            )
        case let .carryNotApplied(source):
            return LocalizedStringResource(
                "Couldn’t move the changes from \(source) into this worktree. They’re still in \(source), unchanged.",
                comment: "New worktree: the changes could not be put here; the argument, twice, is the worktree they stay in"
            )
        case let .carryLeftInSource(source):
            return LocalizedStringResource(
                "Moved the changes here. \(source) changed during the move, so its changes were also left in place.",
                comment: "New worktree: the changes came along but were not taken out of the source; the argument is the source's branch"
            )
        case let .carryPartlyCleared(source, stash?):
            return LocalizedStringResource(
                "Moved the changes here. Some couldn’t be removed from \(source), so a copy was saved as the stash “\(stash)”.",
                comment: "New worktree: the source was cleared part way; the source's branch, then the stash entry's name"
            )
        case let .carryPartlyCleared(source, nil):
            return LocalizedStringResource(
                "Moved the changes here. Some couldn’t be removed from \(source).",
                comment: "New worktree: the source was cleared part way and no copy could be stored; the argument is the source's branch"
            )
        }
    }

    /// The stage's name.
    static func stageName(_ stage: NewSessionStage) -> LocalizedStringResource {
        switch stage {
        case .creatingWorktree: LocalizedStringResource("Creating the worktree", comment: "Stage of a new session")
        case .setup: LocalizedStringResource("Setup", comment: "New worktree: tag while the project's setup commands run")
        case .startingCLI: LocalizedStringResource("Starting the CLI", comment: "Stage of a new session")
        }
    }
}

/// The setup bar laid out from its words: what a failure adds (what to do,
/// the end of its log) stacked above, and the line with the tag, the
/// headline, and the way on in the decision bar's foot bar at the bottom.
/// So the line and its rule stand where every column's foot bar does
/// however tall the bar grows, and a changes panel laid over the terminal,
/// which stops one foot bar above the bottom while a bar is there, never
/// covers Retry or Skip.
/// VoiceOver still reads it from the top of what it says: the headline,
/// what to do, the log, then the buttons.
struct SessionLaunchBarLayout<Actions: View>: View {
    let tag: String
    /// A stage failed: the bar stands on the stop's red.
    let isFailed: Bool
    let isInProgress: Bool
    let headline: String
    /// The headline as VoiceOver reads it.
    let spokenHeadline: String
    let detail: String?
    /// What the failed step printed last; `nil` or empty for nothing.
    let logTail: String?
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        let tail = logTail.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 0) {
            if detail != nil || tail != nil {
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceS) {
                    // What to do, in full: a line cut in the middle would
                    // lose it.
                    if let detail {
                        Text(verbatim: detail)
                            .font(.supervision(.row))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilitySortPriority(2)
                    }
                    if let tail {
                        log(tail)
                            .accessibilitySortPriority(1)
                    }
                }
                .padding(.horizontal, WeirLayout.Supervision.spaceM)
                .padding(.vertical, WeirLayout.Supervision.spaceS)
                // The bar's own top edge, over what it stacks above its
                // line.
                .overlay(alignment: .top) {
                    SupervisionTokens.line.color
                        .frame(height: WeirLayout.Supervision.footBarRuleWidth)
                        .accessibilityHidden(true)
                }
            }
            SupervisionFootBar {
                line
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // On the failure's opaque red the bordered buttons are opaque too,
        // as on the decision bar; otherwise they take the surface's.
        .transformEnvironment(\.supervisionSurfaceOpacity) { opacity in
            if isFailed {
                opacity = 1
            }
        }
        .background(isFailed ? SupervisionTokens.stoppedFill.color : Color.clear)
        // One region, so the order below holds within it and nothing else
        // in the window is read among its parts.
        .accessibilityElement(children: .contain)
    }

    /// The tag, the headline, and the way on.
    private var line: some View {
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            // One element for what the line says, read first; the buttons
            // stay their own, read last. The tag repeats the headline's
            // sense, so the label reads the headline alone, but for a
            // failure, whose headline is the stage's name.
            HStack(spacing: WeirLayout.Supervision.spaceS) {
                DecisionBarTag(text: tag, tone: isFailed ? .stopped : .muted)
                if isInProgress {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(verbatim: headline)
                    .font(.supervision(.row))
                    .lineLimit(1)
                    // A stage names the branch or the folder it works on.
                    .supervisionTruncation(.subject)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: spokenHeadline))
            .accessibilitySortPriority(3)
            Spacer(minLength: WeirLayout.Supervision.spaceS)
            actions()
        }
    }

    /// As tall as a short log; a longer one scrolls in a fixed height,
    /// showing its end, where a step says why it failed.
    private func log(_ tail: String) -> some View {
        Group {
            if SessionLaunchBar.isShort(tail) {
                logText(tail)
            } else {
                ScrollView {
                    logText(tail)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: WeirLayout.Supervision.launchLogMaxHeight)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Log", comment: "New worktree's failed stage, VoiceOver: the end of what the step printed"))
        .accessibilityValue(Text(verbatim: tail))
    }

    private func logText(_ tail: String) -> some View {
        Text(verbatim: tail)
            .font(.supervision(.caption, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
