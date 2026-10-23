// NewSessionOpenMenu.swift
// Limpid — the new worktree sheet's menu of what opens once the worktree is made: each agent, a shell, or nothing.

import AppKit
import SwiftUI

/// What opens once the worktree is made, in a menu whose face is drawn as
/// the base's: every agent the catalog has, each with its badge and its
/// product's name, then a shell and nothing. Segments ran out of room with
/// a third agent; a menu takes any number. An agent not found on this Mac
/// is listed, off and saying so, so a person whose last choice it was sees
/// why the sheet opened with another (`WorktreeOpenChoice.initial`). An
/// AppKit menu (`PopUpMenuButton`), as the changes panel's filter is: a
/// SwiftUI menu draws no badge. The one chosen carries the menu's
/// checkmark, and the button says it to VoiceOver as its value.
struct NewSessionOpenMenu: View {
    /// The row's label, which names the button to VoiceOver.
    let title: LocalizedStringResource
    @Binding var choice: WorktreeOpenChoice
    /// `NewSessionModel.openMenuAgents`.
    let agents: [WorktreeOpenChoice.MenuAgent]
    @Environment(\.locale) private var locale

    var body: some View {
        let chosen = Self.name(choice, locale: locale)
        PopUpMenuButton(
            verbatim: title.resolved(in: locale),
            help: nil,
            value: chosen,
            entries: { entries },
            label: {
                face(chosen)
            }
        )
        .frame(maxWidth: .infinity)
    }

    /// The face: the choice's badge or mark, then its name.
    private func face(_ chosen: String) -> some View {
        NewSessionMenuFace(fillsWidth: true) {
            switch choice {
            case let .agent(kind):
                SessionAgentBadge(
                    badge: .agent(kind),
                    text: SessionRowFactText.badge(.agent(kind), locale: locale),
                    size: .regular
                )
            case .shell:
                ShellPromptBadge()
            case .nothing:
                EmptyView()
            }
            Text(verbatim: chosen)
                .lineLimit(1)
        }
    }

    /// The items, read as the menu opens.
    private var entries: [PopUpMenuEntry] {
        let locale = locale
        let agentItems: [PopUpMenuEntry] = agents.map { agent in
            let name = Self.name(.agent(agent.kind), locale: locale)
            let title = agent.isAvailable ? name : LocalizedStringResource(
                "\(name) (Not Installed)",
                comment: "New worktree sheet: an agent of the Open After Creating menu not found on this Mac; the argument is its name"
            ).resolved(in: locale)
            var item = PopUpMenuItem(
                verbatim: title,
                isChecked: choice == .agent(agent.kind),
                image: { AgentBadgeMenuImage.image(for: agent.kind, size: .regular, in: .current) },
                perform: { choice = .agent(agent.kind) }
            )
            item.isEnabled = agent.isAvailable
            return .item(item)
        }
        let others: [PopUpMenuEntry] = WorktreeOpenChoice.others.map { other in
            // The shell's mark, as the face draws it; nothing has none.
            let image: (@MainActor () -> NSImage?)? = if other == .shell {
                { AgentBadgeMenuImage.shellImage(in: .current) }
            } else {
                nil
            }
            let item = PopUpMenuItem(
                verbatim: Self.name(other, locale: locale),
                isChecked: choice == other,
                image: image,
                perform: { choice = other }
            )
            return PopUpMenuEntry.item(item)
        }
        return agentItems + [.separator] + others
    }

    /// What opens, as the menu says it in `locale`: an agent by its
    /// product's name (Claude Code, not Claude), which the provider gives
    /// itself and no translation changes.
    static func name(_ choice: WorktreeOpenChoice, locale: Locale) -> String {
        switch choice {
        case let .agent(kind):
            AgentProviderRegistry.displayName(for: kind)
        case .shell:
            LocalizedStringResource("Shell").resolved(in: locale)
        case .nothing:
            LocalizedStringResource(
                "None",
                comment: "New worktree sheet: open nothing in the worktree once it is made"
            ).resolved(in: locale)
        }
    }
}
