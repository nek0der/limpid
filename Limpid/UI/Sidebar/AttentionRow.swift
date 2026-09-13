// AttentionRow.swift
// Limpid — container column Waiting list row.
// Extracted from ContainerSlabView to keep that file within the
// file-length budget. Self-contained (no slab-private state).
// Two lines per row: container + wait time, then the agent preview and
// tab title. Keeping one detail line prevents mixed row heights.

import AppKit
import SwiftUI

/// One broker-owned permission request. Decisions go directly to the
/// controller endpoint; focusing the row is optional when the provider
/// session has not yet been associated with a pane.
struct ApprovalAttentionRow: View {
    let approval: ApprovalPresentation
    let isResolving: Bool
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onTap: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(verbatim: "\(approval.provider.rawValue.capitalized) — \(approval.toolName)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            if let summary = approval.summary, !summary.isEmpty {
                Text(verbatim: summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.7))
                    .lineLimit(2)
            }
            Button(showsDetails ? "Hide details" : "Show details") {
                showsDetails.toggle()
            }
            .buttonStyle(.link)
            .controlSize(.small)
            .accessibilityLabel(Text(showsDetails ? "Hide details" : "Show details"))
            if showsDetails {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: approval.inputDescription)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .frame(maxHeight: 160)
            }
            HStack(spacing: 6) {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Deny"))
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(Text("Allow"))
            }
            .disabled(isResolving)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LimpidLayout.containerColumnIndentTop)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .contain)
    }
}

/// One row in the container column Waiting list — in the same order the
/// ⌘J cursor walks. The leading glyph is the agent's state
/// (`questionmark` / `checkmark` / `exclamationmark`) rather than the
/// container's palette dot: the container label on the first line
/// already says which container this is, while nothing else on the row
/// said what the agent actually wants. Tapping the row jumps focus
/// straight to that pane.
struct AttentionRow: View {
    let timestamp: Date
    /// Current time, threaded from the enclosing `TimelineView` so the
    /// relative label re-renders on each tick (one per minute — the
    /// label is "just now" until 1m so we never need second-grain ticks).
    let now: Date
    /// What the agent is waiting for. Drives the leading glyph and its
    /// accessibility label; the visible state name would duplicate it.
    let state: AgentState
    let containerLabel: String
    let tabTitle: String
    let prompt: String?
    /// True when this row's pane is the one currently focused, so the
    /// row is highlighted ("you are here").
    let isCurrent: Bool
    /// Manual dismiss ("conversation's done"); nil hides the × affordance
    /// (needsInput / error rows clear only when the state resolves).
    let onDismiss: (() -> Void)?
    let onTap: () -> Void

    @State private var isHovering = false

    private var elapsed: TimeInterval {
        max(0, now.timeIntervalSince(timestamp))
    }

    /// Compact "how long it's been waiting" label — what matters in
    /// attention is the wait, not the wall clock, so we deliberately drop
    /// the "ago" a relative style would add and let the column read as a
    /// duration. Under a minute we render "just now" (no second-grain
    /// ticking — the row would re-render every second otherwise, which
    /// reads as noise in a calm toolbar). From a minute onward
    /// `Duration`'s units style gives us locale-aware "4m" / "4分"
    /// instead of pinned English.
    private var waitLabel: String {
        if elapsed < 60 {
            return String(localized: "just now")
        }
        return Duration.seconds(elapsed).formatted(
            .units(allowed: [.days, .hours, .minutes], width: .narrow, maximumUnitCount: 1)
        )
    }

    private var stateTint: Color {
        state.iconColor ?? .secondary
    }

    /// One stable detail line. Prompt and tab title used to occupy
    /// separate conditional rows, so fallback titles produced two-line
    /// cells while named tabs produced three-line cells. Preserve both
    /// pieces when they differ, but never repeat the same text.
    private var detailLine: Text? {
        let preview = prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty, !title.isEmpty, preview != title {
            return Text(verbatim: "\(preview) — \(title)")
                .foregroundStyle(Color.primary.opacity(0.45))
        }
        let value = preview.isEmpty ? title : preview
        guard !value.isEmpty else { return nil }
        return Text(verbatim: value)
            .foregroundStyle(Color.primary.opacity(0.7))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Fixed-width glyph well so every row's text starts at the
            // same x no matter which state symbol is shown.
            Image(systemName: state.iconName ?? "circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(stateTint)
                .frame(width: 16)
                // The visible state label is redundant with this glyph,
                // but VoiceOver still needs the semantic state rather
                // than the SF Symbol's mechanical name.
                .accessibilityLabel(Text(state.localizedLabel))
            VStack(alignment: .leading, spacing: 2) {
                // Line 1: which container, and how long it has waited.
                // The right slot shows the wait time, or — on hover, for
                // finished rows — a dismiss ×. They share one slot so
                // nothing overlaps.
                HStack(spacing: 0) {
                    Text(containerLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
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
                        Text(waitLabel)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(Color.primary.opacity(0.4))
                            .fixedSize()
                    }
                }
                // The leading glyph already names the state visually,
                // so the second line carries the preview and, when it
                // adds information, the tab title.
                if let detailLine {
                    detailLine
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LimpidLayout.containerColumnIndentTop)
        .padding(.vertical, 5)
        // The same treatment the container and tab lists use, through
        // the same modifier, rather than a hand-rolled background that
        // drifted from them in radius, inset and hover.
        .selectablePillBackground(isActive: isCurrent, isHovering: isHovering)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .onHover { isHovering = $0 }
        // The whole row is an actionable target — SwiftUI won't add the
        // button trait from `onTapGesture` alone. Combine the child
        // labels (container, state, preview, tab title, wait time) into a
        // single VoiceOver target so the user hears one row at a time.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Jump to this pane"))
    }

}

/// One state's tally in the Waiting header. A named type rather than a
/// tuple so `ForEach` has a stable `Identifiable` element.
private struct AttentionStateCount: Identifiable {
    let state: AgentState
    let count: Int

    var id: AgentState {
        state
    }
}

/// Compact two-way filter whose selected fill travels between segments.
/// AppKit's segmented control swaps its highlight in place; this SwiftUI
/// version matches the review scope switch's visible acknowledgement.
private struct WaitingFilterSwitch: View {
    @Binding var includeViewed: Bool

    @Environment(\.limpidAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frames: [Bool: CGRect] = [:]

    private nonisolated static let space = "waiting-filter-switch"

    private var motion: Animation {
        reduceMotion ? LimpidMotion.reducedSlide : LimpidMotion.paneMergeHighlight
    }

    private var selected: CGRect {
        frames[includeViewed] ?? .zero
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(Text("Next"), tag: false)
            segment(Text("All"), tag: true)
        }
        .coordinateSpace(.named(Self.space))
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(accent)
                .frame(width: selected.width, height: selected.height)
                .offset(x: selected.minX)
                .opacity(selected.isEmpty ? 0 : 1)
        }
        .padding(1)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .animation(motion, value: includeViewed)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Waiting filter"))
        .help(ContainerSlabView.filterHelp(includeViewed: includeViewed))
    }

    private func segment(_ label: Text, tag: Bool) -> some View {
        Button {
            withAnimation(motion) { includeViewed = tag }
        } label: {
            label
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(includeViewed == tag ? Color.white : Color.primary.opacity(0.65))
                .frame(width: 38, height: 16)
                .contentShape(Rectangle())
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(Self.space))
                } action: { frame in
                    frames[tag] = frame
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(includeViewed == tag ? [.isButton, .isSelected] : .isButton)
    }
}

/// Waiting-region helpers that don't touch the slab's private state
/// live here (alongside the row they feed) to keep `ContainerSlabView`
/// within its length budget.
extension ContainerSlabView {
    /// Container column Waiting section header: the label, one count pill
    /// per waiting state, a two-segment filter that hides / shows
    /// viewed-finished rows. `attention` is passed in (rather than read
    /// from the environment here) because the slab's `@Environment`
    /// storage is private to its own file.
    func attentionHeader(
        entries: [AttentionState.AttentionEntry],
        approvalCount: Int = 0,
        attention: AttentionState
    ) -> some View {
        // Severity order, so the state that should pull the eye first is
        // also the leftmost pill.
        let counts = [AgentState.error, .needsInput, .finished]
            .map { state in
                let nativeApprovals = state == .needsInput ? approvalCount : 0
                return AttentionStateCount(
                    state: state,
                    count: entries.count(where: { $0.state == state }) + nativeApprovals
                )
            }
            .filter { $0.count > 0 }
        return ViewThatFits(in: .horizontal) {
            attentionHeaderLine(
                counts: counts,
                totalCount: entries.count + approvalCount,
                attention: attention,
                showsStateBreakdown: true
            )
            attentionHeaderLine(
                counts: counts,
                totalCount: entries.count + approvalCount,
                attention: attention,
                showsStateBreakdown: false
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, LimpidLayout.containerColumnIndentTop)
        .padding(.trailing, LimpidLayout.rowPillInset)
        .padding(.top, 18)
        .padding(.bottom, 10)
    }

    /// The state breakdown is useful at normal widths but, together
    /// with the segmented filter, exceeds the container column's
    /// minimum width. `ViewThatFits` falls back to the aggregate count
    /// before the hosting view can grow wider than the split pane and
    /// pull the rows' selection pills underneath the column edges.
    private func attentionHeaderLine(
        counts: [AttentionStateCount],
        totalCount: Int,
        attention: AttentionState,
        showsStateBreakdown: Bool
    ) -> some View {
        HStack(spacing: 4) {
            // Localized (not `verbatim`) so the string catalog stays
            // the single source of truth, but the ja entry is
            // intentionally "Waiting" too — the workflow lane reads
            // as the same brand-y label in every locale, matching
            // the English GROUPS / PROJECTS category headers above.
            Text("Waiting")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(Color.primary.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            // One number per state rather than a single total: the total
            // never said whether the list holds an error to fix or three
            // finished turns to skim.
            if showsStateBreakdown, !counts.isEmpty {
                HStack(spacing: 4) {
                    ForEach(counts) { pill in
                        HStack(spacing: 2) {
                            Image(systemName: pill.state.iconName ?? "circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(pill.state.iconColor ?? .secondary)
                            Text(verbatim: "\(pill.count)")
                                .font(.system(size: 10, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(Color.primary.opacity(0.55))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(verbatim: "\(pill.state.localizedLabel) \(pill.count)"))
                    }
                }
            } else {
                Text(verbatim: "\(totalCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary.opacity(0.4))
            }
            Spacer(minLength: 2)
            // A labeled two-segment control instead of the eye / slashed
            // eye this used to be: the icon carried the current state but
            // never said what it filtered, so which half of the list it
            // was about was not guessable without toggling it.
            WaitingFilterSwitch(
                includeViewed: Binding(
                    get: { attention.includeViewed },
                    set: { attention.includeViewed = $0 }
                )
            )
        }
    }

    /// Tooltip for the filter segment. Returned as a `LocalizedStringKey`
    /// so both literals resolve through the catalog — a bare ternary
    /// passed to `help(_:)` would collapse to `String` and bypass it.
    fileprivate static func filterHelp(includeViewed: Bool) -> LocalizedStringKey {
        includeViewed
            ? "Show every waiting turn, including ones you have viewed"
            : "Show only turns that still need you"
    }

    /// Preview line for a Waiting row: the state-specific detail
    /// (AskUserQuestion question / permission message for needsInput)
    /// when present, otherwise the turn's prompt. AskUserQuestion and
    /// permission prompts carry their text in `detail`, not `lastPrompt`.
    func attentionPreview(_ entry: AttentionState.AttentionEntry) -> String? {
        if let detail = entry.detail, !detail.isEmpty {
            return detail
        }
        if let prompt = entry.lastPrompt, !prompt.isEmpty {
            return prompt
        }
        return nil
    }
}
