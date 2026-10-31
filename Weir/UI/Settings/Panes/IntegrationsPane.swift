// IntegrationsPane.swift
// Weir — Settings for external configuration and command-line integrations.

import AppKit
import SwiftUI

struct IntegrationsPane: View {
    @Environment(SettingsStore.self) private var store

    @Environment(\.reloadGhosttyConfig) private var reloadGhosttyConfig
    /// The Ghostty config file libghostty reads last, which wins where they
    /// overlap; nil when there is none. Looked up when the pane shows and
    /// when its window comes forward (`refresh`), never while drawing.
    @State private var configFile: URL?
    /// Whether that file was saved after libghostty last read it.
    @State private var isConfigUnread = false
    /// Whether a tmux is installed where agents look for one.
    @State private var isTmuxFound = true
    /// What is at the shell command's place on PATH; nil when this bundle
    /// has no script to link. Read up front so that the section is there for
    /// a search result to scroll to on the first frame.
    @State private var shellCommandStatus = Self.shellCommand?.status()
    /// Whether an install or uninstall is running, which may be for as long
    /// as the administrator prompt stays up.
    @State private var isChangingShellCommand = false
    /// The last install or uninstall's failure, shown until the next try.
    @State private var shellCommandError: DisplayText?
    @Environment(\.locale) private var locale

    private static let shellCommand = ShellCommandInstaller.forThisApp
    private static let isAppOnReadOnlyVolume = shellCommand?.isOnReadOnlyVolume ?? false

    /// The file facts the pane shows, read once rather than on every redraw.
    private func refresh() {
        let file = GhosttyUserConfig.fileToEdit()
        configFile = file
        isConfigUnread = file.map(Self.isUnread) ?? false
        isTmuxFound = TmuxClientProbe.locateTmux() != nil
        shellCommandStatus = Self.shellCommand?.status()
    }

    private func changeShellCommand(_ change: @escaping () async throws -> Void) {
        isChangingShellCommand = true
        shellCommandError = nil
        Task {
            do {
                try await change()
            } catch {
                shellCommandError = DisplayText(error: error)
            }
            isChangingShellCommand = false
            refresh()
        }
    }

    private func perform(_ action: ShellCommandRow.Action, on installer: ShellCommandInstaller) {
        let prompt = ShellCommandInstaller.administratorPrompt.resolved(in: locale)
        switch action {
        case .install, .repair:
            changeShellCommand { try await installer.install(prompt: prompt) }
        case .uninstall:
            changeShellCommand { try await installer.uninstall(prompt: prompt) }
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([installer.link])
        }
    }

    /// Whether `file` changed after libghostty last read the user config.
    private static func isUnread(_ file: URL) -> Bool {
        guard let readAt = GhosttyConfigBridge.userConfigReadAt else { return false }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return modified.map { $0 > readAt } ?? false
    }

    var body: some View {
        form
            .task(id: store.settings.advanced.ghosttyConfig.isOn) {
                refresh()
                // Turning the setting on reloads the config after the
                // settings sync's debounce; look again once it has read
                // the file, so the note compares with that read.
                try? await Task.sleep(for: PersistenceTiming.interactive * 2)
                guard !Task.isCancelled else { return }
                refresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                refresh()
            }
    }

    private var form: some View {
        @Bindable var store = store
        return SettingsForm(title: "Integrations", section: .integrations) {
            Section {
                SettingsToggle(
                    "Use Ghostty config file",
                    isOn: Binding(
                        get: { store.settings.advanced.ghosttyConfig == .on },
                        set: { store.settings.advanced.ghosttyConfig = $0 ? .on : .off }
                    )
                )
                .settingsSearchTarget(SettingsSearchCatalog.ghosttyConfig.id)
                if store.settings.advanced.ghosttyConfig.isOn,
                   !store.ghosttyConfigDiagnostics.isEmpty
                {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Ghostty config errors",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                        ForEach(Array(store.ghosttyConfigDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                // Editing the file is the work this setting asks for, so the
                // file is one click away, as settings.json is in Advanced.
                if let file = configFile {
                    SettingsButtonRow {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                        .accessibilityLabel(Text("Show Ghostty config file in Finder"))
                        Button("Open File") {
                            NSWorkspace.shared.open(file)
                        }
                        .accessibilityLabel(Text("Open Ghostty config file"))
                    }
                    if store.settings.advanced.ghosttyConfig.isOn, isConfigUnread, let reloadGhosttyConfig {
                        HStack(spacing: 12) {
                            SettingsFootnote("The file changed since Weir last read it.")
                            Spacer(minLength: 12)
                            Button("Reload") {
                                reloadGhosttyConfig()
                                refresh()
                            }
                            .help(Text("Reads the Ghostty config file again."))
                        }
                        .settingsControlRow()
                    }
                }
            } header: {
                Text("Ghostty Config")
            } footer: {
                SettingsFootnote(
                    """
                    Loads settings from ~/.config/ghostty/config. Key bindings aren’t applied because \
                    Weir manages its own shortcuts. Weir also takes priority for some safety and display \
                    settings. After editing the file, choose Reload; some settings reach only new terminals.
                    """
                )
            }

            Section {
                SettingsToggle(
                    "Run agents in tmux",
                    isOn: $store.settings.advanced.hostsAgentsInTmux
                )
                .settingsSearchTarget(SettingsSearchCatalog.hostsAgentsInTmux.id)
                // On but with nothing to run: say so, since the agents then
                // run without tmux and stop when Weir quits, the one thing
                // the switch was turned on to avoid.
                if store.settings.advanced.hostsAgentsInTmux, !isTmuxFound {
                    Label {
                        Text("tmux wasn’t found. Agents run without tmux until it is installed, and stop when Weir quits.")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SupervisionTokens.waitingText.color)
                    }
                    .font(.caption)
                }
            } header: {
                Text("tmux")
            } footer: {
                SettingsFootnote(
                    """
                    Starts each agent in a tmux session of its own. The agent keeps running \
                    when Weir quits, including the relaunch after an update, and the pane \
                    reconnects to the same session on the next launch. Requires tmux.

                    Applies to panes opened after the change. The pane’s scrollback stays in \
                    tmux rather than Weir. A command that prints and exits, such as \
                    `claude --version`, runs outside it.
                    """
                )
            }

            if let installer = Self.shellCommand, let shellCommandStatus {
                shellCommandSection(installer, status: shellCommandStatus)
            }
        }
    }

    private func shellCommandSection(_ installer: ShellCommandInstaller, status: ShellCommandStatus) -> some View {
        let row = ShellCommandRow(
            status: status,
            path: installer.link.path,
            isAppOnReadOnlyVolume: Self.isAppOnReadOnlyVolume
        )
        return Section {
            HStack(spacing: 12) {
                Text(display: row.statusText)
                    .settingsSearchTarget(SettingsSearchCatalog.shellCommand.id)
                Spacer(minLength: 12)
                ForEach(row.actions, id: \.self) { action in
                    Button {
                        perform(action, on: installer)
                    } label: {
                        Text(action.title)
                    }
                    .accessibilityLabel(Text(action.accessibilityLabel))
                    .disabled(isChangingShellCommand)
                }
            }
            .settingsControlRow()
            if let shellCommandError {
                Label {
                    Text(display: shellCommandError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(SupervisionTokens.stoppedText.color)
                }
                .font(.caption)
            }
        } header: {
            Text("Shell Command")
        } footer: {
            SettingsFootnote(
                """
                Adds the `\(installer.commandName)` command to the terminal: \
                `\(installer.commandName) .` opens the current folder in Weir as a project. \
                Installing or uninstalling may ask for an administrator password.
                """
            )
        }
    }
}
