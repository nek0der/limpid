// KeyboardShortcutPanel.swift
// Weir — the read-only cheat sheet behind ⌘/ and Help → Keyboard
// Shortcuts. Rows come from `KeyboardShortcutCatalog`, so a rebound
// action shows the user's own binding. Rows do not run their action:
// the panel is for looking things up, and the palette already offers
// runnable rows with the same labels.

import SwiftUI

/// The panel's face, which `KeyboardShortcutOverlay` lays over the window.
struct KeyboardShortcutPanel: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ProjectWindowState.self) private var window
    @Environment(ApprovalPresentationStore.self) private var approvals
    @Environment(\.locale) private var locale

    /// Panel height when the window has room; `minimumHeight` is the
    /// floor below which the list is too short to be useful. The host
    /// picks a value between the two from the window's height.
    static let preferredHeight: CGFloat = 640
    static let minimumHeight: CGFloat = 320

    /// Height the host allows for this window; see `preferredHeight`.
    let maxHeight: CGFloat
    /// Closes the panel and hands the keyboard back.
    let onClose: () -> Void
    /// Opens Settings → Keyboard and closes the panel. Injected so the
    /// panel does not need to know how the window scene routes to a pane.
    let onCustomize: () -> Void

    @State private var query = ""
    /// The control Tab put the accent's ring on; the keyboard itself stays
    /// in the search field (`KeyboardShortcutPanelKeys`).
    @State private var control = KeyboardShortcutPanelKeys.Control.search
    @FocusState private var isSearchFocused: Bool

    private var sections: [KeyboardShortcutSection] {
        KeyboardShortcutCatalog.filter(
            KeyboardShortcutCatalog.sections(
                keyboard: settings.settings.keyboard,
                quickTerminalHotKey: settings.settings.quickTerminal.hotKey,
                locale: locale
            ),
            query: query
        )
    }

    /// The panel's text is drawn in the window's tokens, on the
    /// ground All Projects stands on, so the two read as one kind of
    /// surface.
    var body: some View {
        VStack(alignment: .leading, spacing: WeirLayout.Supervision.sheetSpacing) {
            header
            searchField
            // Built once a pass and handed down: read where it was used,
            // the catalog was built again for each section's heading as the
            // list laid it out while scrolling.
            list(sections)
            footer
        }
        .padding(WeirLayout.Supervision.sheetInsets)
        .frame(width: WeirLayout.Supervision.sheetWidth, height: maxHeight)
        .overlayPanelSurface()
        .background(WindowOverlayKeyMonitor(
            key: KeyboardShortcutPanelKeys.key(for:),
            onKey: handle,
            isPresented: { window.keyboardShortcuts.isPresented },
            isFieldFocused: { isSearchFocused },
            isCardFocused: { window.approvalCard.isFocused },
            reclaimKeyboard: { isSearchFocused = true }
        ))
        .onAppear { KeyboardHandoff.afterResponderSettles { isSearchFocused = true } }
        // Back from the approval card: the field takes the keyboard again.
        .onChange(of: window.approvalCard.isOpen(in: approvals)) { _, isOpen in
            if !isOpen, window.keyboardShortcuts.isPresented {
                isSearchFocused = true
            }
        }
        // Typing goes to the field, whatever Tab had drawn as focused.
        .onChange(of: query) { _, _ in
            control = .search
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Keyboard Shortcuts"))
        .accessibilityAddTraits(.isModal)
    }

    private func handle(_ key: KeyboardShortcutPanelKeys.Key) {
        switch key {
        case .close:
            onClose()
        case .nextControl, .previousControl:
            control = control.next(backward: key == .previousControl)
            isSearchFocused = true
        case .press:
            switch control {
            case .search: break
            case .customize: onCustomize()
            case .close: onClose()
            }
        }
    }

    /// A panel for looking things up closes with ×, Esc, and a click
    /// outside it: the footer has no Close of its own to find. Esc is
    /// the key monitor's (`WindowOverlayKeyMonitor`), which also knows when
    /// the keyboard is in the approval card. The × is one of the panel's
    /// Tab stops (`KeyboardShortcutPanelKeys.Control.close`), and Return
    /// presses it while the ring is on it.
    private var header: some View {
        SupervisionSheetHeader(
            title: Text("Keyboard Shortcuts"),
            onClose: onClose,
            closeHelp: "Close (⎋)",
            isCloseFocused: control == .close,
            leading: { EmptyView() },
            trailing: { EmptyView() }
        )
        // As tall as All Projects' title line, which holds its filter, so
        // the two panels' titles stand at the same height in them.
        .frame(minHeight: WeirLayout.Supervision.panelSearchFieldHeight)
    }

    private var searchField: some View {
        PanelSearchField(
            text: $query,
            prompt: Text("Search shortcuts"),
            isFocused: $isSearchFocused,
            showsRing: control == .search
        )
    }

    @ViewBuilder
    private func list(_ sections: [KeyboardShortcutSection]) -> some View {
        if sections.isEmpty {
            SupervisionEmptyState(.noMatchingShortcuts, size: .regular)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(verbatim: section.title)
                            .font(.supervision(.meta))
                            .foregroundStyle(SupervisionTokens.muted.color)
                            .padding(WeirLayout.Supervision.headingInsets(isFirst: section.id == sections.first?.id))
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.entries) { entry in
                            KeyboardShortcutRow(entry: entry)
                        }
                    }
                }
                .padding(.bottom, WeirLayout.Supervision.spaceS)
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The way elsewhere at the start, as a dialog's auxiliary button sits:
    /// alone at the end, it would read as the panel's own action.
    private var footer: some View {
        SupervisionSheetFooter {
            Button(action: onCustomize) {
                Text("Customize…")
            }
            .buttonStyle(.supervisionSecondary)
            .supervisionFocusRing(isFocused: control == .customize, cornerRadius: WeirLayout.Supervision.buttonCornerRadius)
            // The control Return presses, said as the ring shows it.
            .accessibilityAddTraits(control == .customize ? .isSelected : [])
            .help("Open Keyboard settings")
            // VoiceOver says where the button goes, as the tooltip does;
            // "Customize…" alone does not say what it customizes.
            .accessibilityLabel(Text("Open Keyboard settings"))
        } trailing: {
            EmptyView()
        }
    }
}

/// The name is the row's text, in the text color, and the keys are what
/// is quieter.
private struct KeyboardShortcutRow: View {
    let entry: KeyboardShortcutEntry

    var body: some View {
        HStack(spacing: WeirLayout.Supervision.spaceS) {
            Text(verbatim: entry.title)
                .font(.supervision(.body))
                .foregroundStyle(SupervisionTokens.text.color)
                .lineLimit(1)
            Spacer(minLength: WeirLayout.Supervision.spaceXL)
            KeycapRow(tokens: entry.tokens)
        }
        .padding(WeirLayout.Supervision.popoverRowInsets)
        .accessibilityElement(children: .combine)
    }
}
