// IntegrationsPane.swift
// Limpid — Settings for external configuration and command-line integrations.

import SwiftUI

struct IntegrationsPane: View {
    @Environment(SettingsStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsForm(title: "Integrations", section: .integrations) {
            Section {
                Toggle(
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
                        .foregroundStyle(.red)
                        ForEach(Array(store.ghosttyConfigDiagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
            } header: {
                Text("Ghostty Config")
            } footer: {
                Text(
                    """
                    Loads settings from ~/.config/ghostty/config. Key bindings are not applied because \
                    Limpid manages its own shortcuts. Limpid also takes priority for some safety and display \
                    settings. Restart Limpid after editing the file.
                    """
                )
            }

            Section {
                Toggle(
                    "Show PR status in sidebar",
                    isOn: $store.settings.advanced.showPRStatusInSidebar
                )
                .settingsSearchTarget(SettingsSearchCatalog.showPRStatus.id)
                Toggle(
                    "Mark only rows needing attention",
                    isOn: $store.settings.advanced.showPRStatusOnlyWhenAttention
                )
                .disabled(!store.settings.advanced.showPRStatusInSidebar)
                .settingsSearchTarget(SettingsSearchCatalog.showPRStatusOnlyWhenAttention.id)
            } header: {
                Text("Pull Requests")
            } footer: {
                Text(
                    """
                    Marks a sidebar row whose branch has a pull request, and shows the title \
                    and CI summary on hover. Requires `gh` (GitHub) or `glab` (GitLab), \
                    signed in to the remote's host. \
                    Refreshes on focus, every \(PRStatusSyncer.refreshIntervalMinutes) minutes \
                    otherwise, and faster while checks are running.

                    Restricting the mark to rows with a failing check leaves fewer of them \
                    on screen; the hover card reports every request either way.
                    """
                )
            }

            Section {
                Toggle(
                    "Show agents in a tmux tab",
                    isOn: $store.settings.advanced.hostsAgentsInTmux
                )
                .disabled(!store.agentTmuxSupport.allowsHostingSetting)
                .settingsSearchTarget(SettingsSearchCatalog.hostsAgentsInTmux.id)
                if let reason = tmuxUnavailability {
                    reason
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("tmux")
            } footer: {
                Text(
                    """
                    Starts each agent in a tmux session of its own and shows that session as \
                    its own tab. The agent keeps running after Limpid quits, including the \
                    relaunch after an update, and the tab reconnects to it on the next \
                    launch. The command you typed returns to the prompt as soon as the tab \
                    opens.

                    Applies to panes opened after the change. The agent's scrollback is \
                    Limpid's, not tmux's. Reviewing a turn is not available in these tabs \
                    yet. A command that prints and exits, such as `claude --version`, runs \
                    outside tmux.
                    """
                )
            }
        }
    }

    /// What the launch probe found, when what it found is the reason the
    /// setting cannot be switched on. A tab is opened by attaching to the
    /// agent's session, so a tmux a mirror cannot attach to leaves nothing to
    /// offer, and the reason belongs next to the switch rather than in a log.
    private var tmuxUnavailability: Text? {
        let minimum = TmuxMirrorTarget.minimumVersion.description
        switch store.agentTmuxSupport {
        case .pending, .supported:
            return nil
        case .notInstalled:
            return Text("No tmux found. Showing agents in a tab needs tmux \(minimum) or newer.")
        case .unreadableVersion:
            return Text(
                """
                Limpid could not read the version of the tmux it found. Showing agents in a \
                tab needs tmux \(minimum) or newer.
                """
            )
        case let .unsupported(_, version):
            return Text(
                """
                The tmux found is version \(version.description). Showing agents in a tab \
                needs \(minimum) or newer.
                """
            )
        }
    }
}
