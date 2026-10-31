// AddTabMenu.swift
// Weir — the pane strip's "+" menu: a Claude, Codex, or shell tab in this session.

import SwiftUI
import WeirDomain

/// What the strip's "+" adds to the session it heads: a tab running Claude
/// or Codex, or a shell. An agent added here works in the same folder as
/// the session's own, so its items say so; a new folder is a new session.
/// It takes the keyboard as it opens: ↑↓ move through the items from the
/// first, and Return adds the selected one (`DropdownListKeys`).
struct AddTabMenu: View {
    /// The menu's items, in order, as the keys move through them.
    enum Item: CaseIterable, Hashable {
        case claude
        case codex
        case shell

        /// The agent the tab runs; `nil` for a shell.
        var agent: AgentKind? {
            switch self {
            case .claude: .claude
            case .codex: .codex
            case .shell: nil
            }
        }
    }

    let container: ContainerID
    let dismiss: () -> Void
    @Environment(WorkspaceSession.self) private var session
    @Environment(SettingsStore.self) private var settings
    /// The window the menu is in, whose selection the new tab is shown in.
    @Environment(ProjectWindowState.self) private var window
    @Environment(\.locale) private var locale
    @State private var selection = ListKeyboardSelection<Item>(ids: [])

    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.popoverRowSpacing) {
            // A branch or folder in code type, as the title bar names a
            // branch; "Scratch" is our word, and stays in the sentence's.
            Text("Add Tab to \(Text(verbatim: placeName).font(placeFont))")
                .font(.supervision(.meta))
                .foregroundStyle(SupervisionTokens.muted.color)
                .lineLimit(1)
                // The sentence ends in the place, a branch after its
                // project, whose end stays.
                .supervisionTruncation(.subject)
                .padding(WeirLayout.Supervision.dropdownHeadingInsets)
                .accessibilityAddTraits(.isHeader)
            ForEach(Item.allCases, id: \.self) { item in
                AddTabMenuItem(
                    title: title(of: item),
                    agent: item.agent,
                    caption: item.agent == nil ? nil : sharedFolderCaption,
                    shortcut: item == .shell ? settings.settings.keyboard.shortcut(for: .newTab)?.displayString : nil,
                    isSelected: item == selection.id,
                    // The pointer selects, so one item is lit: the one
                    // Return adds.
                    onHover: { selection.select(item) },
                    action: { add(running: item.agent) }
                )
            }
        }
        .padding(WeirLayout.Supervision.dropdownPadding)
        .dropdownListKeys(Item.allCases, selection: $selection) { item in
            add(running: item.agent)
        }
    }

    /// An agent by its product name, the catalog's, the same in every
    /// language; "Shell" is our word.
    private func title(of item: Item) -> Text {
        guard let agent = item.agent else { return Text("Shell") }
        return Text(verbatim: AgentCatalog.entry(for: agent).displayName)
    }

    /// The branch or folder the tab opens in, or "Scratch".
    private var placeName: String {
        Self.placeName(of: container, in: session, locale: locale)
    }

    private var placeFont: Font {
        Self.isNamedPlace(container, in: session) ? .supervisionCode(beside: .meta) : .supervision(.meta)
    }

    /// Whether the place is a branch or a folder, named by the repository
    /// or the disk, rather than "Scratch".
    @MainActor
    static func isNamedPlace(_ container: ContainerID, in session: WorkspaceSession) -> Bool {
        if case .named? = CheckoutName.place(of: container, in: session) {
            return true
        }
        return false
    }

    /// The branch or folder a tab added to `container` opens in, or
    /// "Scratch": the menu's heading and the "+"'s tooltip name it.
    @MainActor
    static func placeName(of container: ContainerID, in session: WorkspaceSession, locale: Locale) -> String {
        // A project the session no longer has has no name of its own, so
        // the heading falls back to the one name a tab's place always has.
        guard case let .named(name)? = CheckoutName.place(of: container, in: session) else {
            return LocalizedStringResource("Scratch").resolved(in: locale)
        }
        return name
    }

    private var sharedFolderCaption: Text {
        Text("Runs in the same folder. Editing at the same time may cause conflicts.")
    }

    private func add(running agent: AgentKind?) {
        dismiss()
        TabActions.newTab(session, in: container, running: agent, window: window.id, intent: .person, selects: true)
    }
}

/// One item: the badge the new tab will wear, its name, and the key that
/// adds it from anywhere. An agent's item also says, in a line of its own,
/// that it shares the session's folder.
private struct AddTabMenuItem: View {
    let title: Text
    /// The agent the tab runs, whose badge the item shows; `nil` for a
    /// shell.
    let agent: AgentKind?
    let caption: Text?
    /// "⌘T", as the person has it assigned.
    var shortcut: String?
    /// The arrow keys' item, or the one under the pointer.
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: WeirLayout.Supervision.spaceS) {
                PaneStripTabBadge(agent: agent)
                    .alignmentGuide(.firstTextBaseline) {
                        $0[VerticalAlignment.center] + WeirLayout.Supervision.addTabMenuBadgeRaise
                    }
                VStack(alignment: .leading, spacing: WeirLayout.Supervision.spaceHairline) {
                    title
                        .font(.supervision(.body))
                        .foregroundStyle(SupervisionTokens.text.color)
                    if let caption {
                        caption
                            .font(.supervision(.caption))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: WeirLayout.Supervision.spaceS)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.supervision(.meta))
                        .foregroundStyle(SupervisionTokens.muted.color)
                }
            }
            .padding(WeirLayout.Supervision.addTabMenuItemInsets)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The pointer selects the item it is over (`onHover`), so the
            // selection's fill is the only one the item draws.
            .dropdownRowBackground(
                isSelected: isSelected,
                isHovering: false,
                cornerRadius: WeirLayout.Supervision.addTabMenuItemCornerRadius
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering in
            if isHovering {
                onHover()
            }
        }
    }
}
