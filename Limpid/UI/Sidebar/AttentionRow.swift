// AttentionRow.swift
// Limpid — container column Waiting list row card + its resize divider handle.
// Extracted from ContainerSlabView to keep that file within the
// file-length budget. Both are self-contained (no slab-private state).

import AppKit
import SwiftUI

/// One row in the container column Waiting list — an expanded card in the same
/// order the ⌘J cursor walks: timestamp, the owning container (color
/// dot + name), the tab title, and a one-line prompt preview. Tapping
/// it jumps focus straight to that pane.
struct AttentionRow: View {
    let timestamp: Date
    /// Current time, threaded from the enclosing `TimelineView` so the
    /// relative label re-renders on each tick (one per minute — the
    /// label is "just now" until 1m so we never need second-grain ticks).
    let now: Date
    let containerLabel: String
    let containerColor: Color
    /// SF Symbol for the leading glyph when the container has no palette
    /// color to show as a dot (Quick Tabs); nil → render the color dot.
    let containerIcon: String?
    let tabTitle: String
    let prompt: String?
    /// True when this row's pane is the one currently focused, so the
    /// card is highlighted ("you are here").
    let isCurrent: Bool
    /// True once focus has visited this finished pane — the row fades to
    /// "seen, not yet replied". Cleared when the agent's next turn starts.
    let isViewed: Bool
    /// Manual dismiss ("conversation's done"); nil hides the × affordance
    /// (needsInput / error rows clear only when the state resolves).
    let onDismiss: (() -> Void)?
    let onTap: () -> Void

    @State private var isHovering = false

    /// Compact "how long it's been waiting" label — what matters in
    /// attention is the wait, not the wall-clock. Under a minute we render
    /// "just now" (no second-grain ticking — the row would re-render
    /// every second otherwise, which reads as noise in a calm toolbar).
    /// From a minute onward we hand off to `Date.RelativeFormatStyle` so
    /// the m / h / d labels follow `Locale.current` instead of pinning
    /// English `m`/`h`/`d ago`.
    private var relativeLabel: String {
        let elapsed = max(0, Int(now.timeIntervalSince(timestamp)))
        if elapsed < 60 { return String(localized: "just now") }
        return timestamp.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Top line: color dot + container name (truncates). The
            // right slot shows the wait-time, or — on hover, for finished
            // rows — a dismiss ×. They share one slot so nothing overlaps.
            HStack(spacing: 5) {
                // Fixed-width glyph well so the dot and the Quick Tabs
                // icon share one center line and the label always starts
                // at the same x regardless of which is shown.
                ZStack {
                    if let containerIcon {
                        Image(systemName: containerIcon)
                            .font(.system(size: 10))
                            .foregroundStyle(containerColor)
                    } else {
                        Circle()
                            .fill(containerColor)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 16)
                Text(containerLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if isHovering, let onDismiss {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .contentShape(Rectangle())
                        .onTapGesture { onDismiss() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(Text("Dismiss"))
                } else {
                    Text(relativeLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .fixedSize()
                }
            }
            Text(tabTitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
            if let prompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 5)
        // Faded once seen, full-strength while it still wants a reply.
        .opacity(isViewed ? 0.5 : 1)
        .background(alignment: .center) {
            if isCurrent {
                // White-system selection (matches container column/tab column row treatment) —
                // not the accent blue, which clashed.
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.08))
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
        // The whole card is an actionable row — SwiftUI won't add the
        // button trait from `onTapGesture` alone. Combine the child
        // labels (container, tab title, prompt, relative time) into a
        // single VoiceOver target so the user hears one row at a time.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Jump to this pane"))
    }
}

/// Horizontal drag handle that resizes the Waiting region. Mirrors
/// `DividerResizeHandle` (the container column/tab column width splitter) but on the vertical
/// axis and storing a fraction of slab height. Drag up to grow the
/// region, down to shrink; double-click resets to the default fraction.
struct AttentionDividerHandle: View {
    let currentFraction: () -> CGFloat
    let setFraction: (CGFloat) -> Void
    let slabHeight: CGFloat

    @State private var dragStartFraction: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: LimpidLayout.attentionResizeHandleHeight)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 1)
                // Inset the rule so it doesn't run edge-to-edge into the
                // sidebar frame; matches the header's horizontal padding.
                .padding(.horizontal, 18)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            TapGesture(count: 2)
                .onEnded {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        setFraction(LimpidLayout.attentionHeightFraction)
                    }
                }
                .exclusively(before:
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { value in
                            if dragStartFraction == nil { dragStartFraction = currentFraction() }
                            guard slabHeight > 0 else { return }
                            // Dragging up (negative translation) grows
                            // the bottom region, so subtract.
                            let deltaFraction = -value.translation.height / slabHeight
                            let next = (dragStartFraction ?? currentFraction()) + deltaFraction
                            // Floor the fraction so the rendered point
                            // height also respects `attentionMinHeight`
                            // — dragging never collapses past the 0-item
                            // hint in a short sidebar.
                            let pointFloor = slabHeight > 0
                                ? LimpidLayout.attentionMinHeight / slabHeight
                                : LimpidLayout.attentionMinFraction
                            let minFraction = max(LimpidLayout.attentionMinFraction, pointFloor)
                            setFraction(min(
                                max(next, minFraction),
                                LimpidLayout.attentionMaxFraction
                            ))
                        }
                        .onEnded { _ in dragStartFraction = nil }
                )
        )
    }
}

/// Waiting-region helpers that don't touch the slab's private state
/// live here (alongside the row they feed) to keep `ContainerSlabView`
/// within its length budget.
extension ContainerSlabView {
    /// Container column Waiting section header: the label, a live count of waiting
    /// panes, an eye toggle that hides / shows viewed-finished rows, and
    /// a ⌘J keycap advertising the jump shortcut. `attention` is passed in
    /// (rather than read from the environment here) because the slab's
    /// `@Environment` storage is private to its own file.
    func attentionHeader(count: Int, attention: AttentionState, accent: Color) -> some View {
        HStack(spacing: 6) {
            // Localized (not `verbatim`) so the string catalog stays
            // the single source of truth, but the ja entry is
            // intentionally "Waiting" too — the workflow lane reads
            // as the same brand-y label in every locale, matching
            // the English GROUPS / PROJECTS category headers above.
            Text("Waiting")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.primary.opacity(0.55))
            Text(verbatim: "\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.4))
                .monospacedDigit()
            Spacer()
            // Filter toggle — open eye shows everything (default); slashed
            // eye hides viewed-finished rows so the list is just "next
            // to deal with". needsInput / error are never hidden.
            Button {
                attention.includeViewed.toggle()
            } label: {
                Image(systemName: attention.includeViewed ? "eye" : "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(attention.includeViewed
                        ? Color.primary.opacity(0.4)
                        : accent.opacity(0.8))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(attention.includeViewed
                ? "Hide already-viewed (show only next-to-deal-with)"
                : "Show all (including already-viewed)")
            Text(verbatim: "⌘J")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.4))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// Preview line for a Waiting row: the state-specific detail
    /// (AskUserQuestion question / permission message for needsInput)
    /// when present, otherwise the turn's prompt. AskUserQuestion and
    /// permission prompts carry their text in `detail`, not `lastPrompt`.
    func attentionPreview(_ entry: AttentionState.AttentionEntry) -> String? {
        if let detail = entry.detail, !detail.isEmpty { return detail }
        if let prompt = entry.lastPrompt, !prompt.isEmpty { return prompt }
        return nil
    }

    /// Leading glyph for a Waiting row: Quick Tabs (`.loose`) has no
    /// palette color, so we show an icon instead of a meaningless dot.
    /// Groups / Projects keep their color dot (it encodes which one).
    func containerIcon(for container: ContainerID) -> String? {
        if case .loose = container { "tray.full" } else { nil }
    }
}
