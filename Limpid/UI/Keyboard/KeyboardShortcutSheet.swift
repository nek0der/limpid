// KeyboardShortcutSheet.swift
// Limpid — the read-only cheat sheet behind ⌘/ and Help → Keyboard
// Shortcuts. Rows come from `KeyboardShortcutCatalog`, so a rebound
// action shows the user's own binding. Rows do not run their action:
// the sheet is for looking things up, and the palette already offers
// runnable rows with the same labels.

import SwiftUI

struct KeyboardShortcutSheet: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// Sheet height when the window has room; `minimumHeight` is the
    /// floor below which the list is too short to be useful. The host
    /// picks a value between the two from the window's height.
    static let preferredHeight: CGFloat = 640
    static let minimumHeight: CGFloat = 320

    /// Height the host allows for this window; see `preferredHeight`.
    let maxHeight: CGFloat
    /// Opens Settings → Keyboard. Injected so the sheet does not need
    /// to know how the window scene routes to a pane.
    let onCustomize: () -> Void

    @State private var query = ""
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            searchField
            list
            footer
        }
        .padding(20)
        .frame(width: 560, height: maxHeight)
        .onAppear { isSearchFocused = true }
    }

    private var header: some View {
        HStack {
            Text("Keyboard Shortcuts")
                .font(LimpidFont.title)
            Spacer()
            DismissGlyphButton(label: "Close", size: .large) {
                dismiss()
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LimpidColor.secondaryText)
                .accessibilityHidden(true)
            TextField("Search shortcuts", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .accessibilityLabel(Text("Search shortcuts"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(LimpidColor.rowActiveFill)
        )
    }

    @ViewBuilder
    private var list: some View {
        if sections.isEmpty {
            Text("No shortcuts match")
                .font(LimpidFont.body)
                .foregroundStyle(LimpidColor.secondaryText)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(verbatim: section.title)
                            .font(LimpidFont.headline)
                            .foregroundStyle(LimpidColor.primaryText)
                            .padding(.top, 14)
                            .padding(.bottom, 6)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(section.entries) { entry in
                            KeyboardShortcutRow(entry: entry)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack {
            Button {
                onCustomize()
                dismiss()
            } label: {
                Text("Customize…")
            }
            .help("Open Keyboard settings")
            Spacer()
            Button {
                dismiss()
            } label: {
                Text("Close")
                    .frame(minWidth: 80)
            }
            .keyboardShortcut(.cancelAction)
        }
    }
}

private struct KeyboardShortcutRow: View {
    let entry: KeyboardShortcutEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: entry.title)
                .font(LimpidFont.bodySecondary)
                .foregroundStyle(LimpidColor.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 24)
            KeycapRow(tokens: entry.tokens)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
