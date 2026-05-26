// PromptHistorySidebar.swift
// Limpid — right-edge L3 sidebar that lists every Claude prompt the
// user has submitted in each split-pane of the active tab. Tapping a
// row fires `jump_to_prompt:-N` on the pane's surface so the
// terminal scrolls back to the matching OSC 133;A marker the hook
// emitted at submit time.
//
// Layout follows the (c) "header tabs" extensibility path: one pane
// chip per split-leaf in the active tab, the chip strip lives in the
// sidebar header, body shows the prompts for the currently-selected
// chip. Switching tabs swaps the chip strip; switching panes
// preserves visibility but updates `WindowSession.promptSidebarSelectedPaneID`.

import SwiftUI

struct PromptHistorySidebar: View {
    @Environment(WindowSession.self) private var session
    @Environment(\.surfaceRegistry) private var registry

    var body: some View {
        let tab = activeTab
        VStack(spacing: 0) {
            header(tab: tab)
            Divider().opacity(0.2)
            body(tab: tab)
        }
        .frame(width: session.promptSidebarWidth)
        .background(LimpidColor.l3Background.opacity(0.92))
    }

    private var activeTab: Tab? {
        guard let id = session.activeTabID else { return nil }
        return session.tabs.first { $0.id == id }
    }

    // MARK: - Header

    @ViewBuilder
    private func header(tab: Tab?) -> some View {
        HStack(spacing: 8) {
            Text("Prompts")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.leading, 12)
            Spacer(minLength: 4)
            Button {
                @Bindable var session = session
                session.promptSidebarVisible = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .padding(.trailing, 6)
        }
        .frame(height: 32)
        if let tab, !leafIDs(in: tab).isEmpty {
            paneChipStrip(tab: tab)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func paneChipStrip(tab: Tab) -> some View {
        let leaves = leafIDs(in: tab)
        // Multiple split panes → one chip each. Single-pane tabs
        // skip the strip entirely so the header doesn't waste
        // vertical space on a single dot.
        if leaves.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(leaves.enumerated()), id: \.element) { idx, leafID in
                        paneChip(
                            label: "Pane \(idx + 1)",
                            leafID: leafID,
                            isSelected: leafID == effectiveSelectedPane(tab: tab, leaves: leaves)
                        )
                    }
                }
            }
        }
    }

    private func paneChip(label: String, leafID: UUID, isSelected: Bool) -> some View {
        Button {
            @Bindable var session = session
            session.promptSidebarSelectedPaneID = leafID
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? LimpidColor.rowHoverFill : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body

    @ViewBuilder
    private func body(tab: Tab?) -> some View {
        if let tab {
            let leaves = leafIDs(in: tab)
            if leaves.isEmpty {
                emptyState
            } else {
                let selected = effectiveSelectedPane(tab: tab, leaves: leaves)
                let prompts = tab.claudePrompts[selected] ?? []
                if prompts.isEmpty {
                    emptyState
                } else {
                    promptList(prompts: prompts, leafID: selected)
                }
            }
        } else {
            emptyState
        }
    }

    private func promptList(prompts: [ClaudePromptEntry], leafID: UUID) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.element.id) { idx, entry in
                    PromptRow(
                        entry: entry,
                        onTap: {
                            jumpToPrompt(
                                tappedIndex: idx,
                                totalPrompts: prompts.count,
                                leafID: leafID
                            )
                        }
                    )
                    Divider().opacity(0.12).padding(.leading, 14)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No prompts yet")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private func leafIDs(in tab: Tab) -> [UUID] {
        tab.splitTree.allLeafIDs()
    }

    /// Resolve which pane's prompts to render. Prefers the explicit
    /// session selection when it still maps to a live leaf in the
    /// active tab; otherwise falls back to the first leaf so the
    /// sidebar always shows *something* useful when toggled open.
    private func effectiveSelectedPane(tab: Tab, leaves: [UUID]) -> UUID {
        if let id = session.promptSidebarSelectedPaneID, leaves.contains(id) {
            return id
        }
        return leaves[0]
    }

    /// Fire `jump_to_prompt:-(delta)` against the pane's surface so
    /// ghostty scrolls back to the OSC 133;A marker the hook emitted
    /// when the user originally submitted this prompt. `delta` is
    /// the count of prompts *between* the latest marker and the
    /// tapped one, which is exactly what `jump_to_prompt` consumes.
    private func jumpToPrompt(tappedIndex: Int, totalPrompts: Int, leafID: UUID) {
        let delta = totalPrompts - 1 - tappedIndex
        guard delta >= 0 else { return }
        guard let view = registry.view(for: leafID),
              let surface = view.surface else { return }
        // `jump_to_prompt:-0` is a no-op; map the latest row to a
        // simple `scroll_to_bottom` so the click still feels live.
        let action = delta == 0 ? "scroll_to_bottom" : "jump_to_prompt:-\(delta)"
        GhosttyFFI.bindingAction(surface, action: action)
    }
}

private struct PromptRow: View {
    let entry: ClaudePromptEntry
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(timeLabel)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? LimpidColor.rowHoverFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var displayText: String {
        entry.text.isEmpty
            ? String(localized: "(empty prompt)")
            : entry.text
    }

    private var timeLabel: String {
        // The hook writes `submittedAt` as ISO-8601 UTC. Render in
        // the user's locale; fall back to the raw string when
        // parsing fails so the row never goes blank.
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: entry.submittedAt) {
            let display = DateFormatter()
            display.dateStyle = .none
            display.timeStyle = .short
            return display.string(from: date)
        }
        return entry.submittedAt
    }
}
