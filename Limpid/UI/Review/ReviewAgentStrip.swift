// ReviewAgentStrip.swift
// Limpid — the divider above the origin pane and the destination it names.

import SwiftUI

/// Sits between the review surface and the origin pane. It doubles as the
/// statement of where feedback goes: the pane below is the destination, so
/// naming it here removes the need for a separate picker.
struct ReviewAgentStripHeader: View {
    let paneID: UUID
    /// Height of the area the strip shares with the review surface, so a drag
    /// cannot push the pane past what the window can show.
    let available: CGFloat
    @Environment(WindowSession.self) private var session
    @Environment(ReviewPresentation.self) private var reviewPresentation
    @Environment(\.surfaceRegistry) private var registry
    /// Height when the drag started. Without it every delta would compound.
    @State private var dragOrigin: CGFloat?

    /// Every pane of the tab this one sits in. Review docks one at a time, so
    /// this is what makes the others reachable — from the terminal's own
    /// heading, where the pane it names already is.
    private var panes: [ReviewDestination] {
        guard let tab = session.tab(containing: paneID) else { return [] }
        return tab.splitTree.allLeafIDs().compactMap {
            ReviewAgents.destination(session: session, paneID: $0, registry: registry)
        }
    }

    /// The menu's entries. Two shells in the same worktree resolve to the same
    /// name, and a list of identical names is not a choice — those get the
    /// position they sit at in the tab.
    private var paneChoices: [(destination: ReviewDestination, label: String)] {
        let all = panes
        var counts: [String: Int] = [:]
        for pane in all {
            counts[pane.title, default: 0] += 1
        }
        return all.enumerated().map { index, pane in
            let label = counts[pane.title, default: 0] > 1
                ? "\(pane.title) \(index + 1)"
                : pane.title
            return (pane, label)
        }
    }

    private var paneTitle: String {
        panes.first { $0.paneID == paneID }?.title
            ?? session.tab(containing: paneID)?.title
            ?? String(localized: "Pane")
    }

    private var isCollapsed: Bool {
        reviewPresentation.isStripCollapsed
    }

    /// Wake a pane before the layout mounts it.
    ///
    /// Review tells libghostty to stop drawing every pane but the docked one.
    /// Expanding the strip, and pointing it at a different pane, both mount a
    /// surface that is still asleep, and the occlusion pass that wakes it runs
    /// after the mount — so its first frame is whatever its layer last held.
    private func reveal(_ paneID: UUID) {
        registry.updateOcclusion(visibleIDs: [paneID])
    }

    var body: some View {
        HStack(spacing: 9) {
            paneSwitcher
            Spacer(minLength: 8)
            Button {
                // Expanding mounts the pane again; waking it first is what
                // keeps its first frame from being the one it was put to
                // sleep on.
                if isCollapsed {
                    reveal(paneID)
                }
                reviewPresentation.toggleStrip()
            } label: {
                Label {
                    Text(isCollapsed ? "Show" : "Collapse")
                } icon: {
                    // One pair, not two unrelated symbols: down puts the
                    // terminal away, up brings it back.
                    Image(systemName: isCollapsed ? "chevron.up" : "chevron.down")
                }
                .font(LimpidFont.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(LimpidColor.secondaryText)
            .accessibilityLabel(Text(isCollapsed ? "Show Terminal" : "Collapse Terminal"))
            .help(Text(isCollapsed ? "Show Terminal" : "Collapse Terminal"))
            .pointerOverHandle()
        }
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(LimpidColor.rowActiveFill.pointerStyle(.rowResize))
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        // The divider is the handle: a terminal's useful height depends on what
        // the agent is printing, which no set of fixed stops can guess.
        .contentShape(Rectangle())
        // Simultaneous, not exclusive: an exclusive drag on the header would
        // swallow clicks on the collapse button inside it.
        .simultaneousGesture(resize)
        // Double-click restores the default height, the same gesture the split
        // dividers use to equalize.
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                reviewPresentation.resizeStrip(to: ReviewStrip.default, in: available)
            }
        )
        .accessibilityElement(children: .contain)
        // Dragging is the only other way to set this height, and a divider is
        // not something a reader without a pointer can aim at.
        .accessibilityLabel(Text("Terminal Height"))
        .accessibilityValue(
            isCollapsed
                ? Text("Collapsed")
                : Text(verbatim: "\(Int((reviewPresentation.stripHeight(in: available) ?? 0).rounded()))")
        )
        .accessibilityAdjustableAction { direction in
            // Collapsed there is nothing below to take from, and growing brings
            // the pane back — the same wake the button does, because mounting it
            // again otherwise shows the frame it was put to sleep on.
            guard !isCollapsed else {
                guard direction == .increment else { return }
                reveal(paneID)
                reviewPresentation.resizeStrip(to: ReviewStrip.default, in: available)
                return
            }
            let current = reviewPresentation.stripHeight(in: available) ?? ReviewStrip.default
            reviewPresentation.resizeStrip(
                to: current + (direction == .increment ? 1 : -1) * ReviewRowMetrics.strideForResize,
                in: available
            )
        }
        .help(Text("Drag to resize, double-click to reset"))
    }

    private var isPinned: Bool {
        reviewPresentation.isDestinationPinned
    }

    /// The pane the feedback goes to, named, with a way to pick another and a
    /// way to say whether the choice sticks. It lives here rather than on the
    /// destination chip so the chip reads the same whatever the tab contains.
    ///
    /// A menu even where the tab holds one pane: following the focus is a
    /// decision about every tab in the window, not only about this one, and
    /// the reader with a single pane in front of them is exactly the one who
    /// will otherwise find the destination somewhere else later.
    private var paneSwitcher: some View {
        Menu {
            if paneChoices.count > 1 {
                ForEach(paneChoices, id: \.destination.paneID) { choice in
                    Button {
                        select(choice.destination.paneID)
                    } label: {
                        if choice.destination.paneID == paneID {
                            Label(choice.label, systemImage: "checkmark")
                        } else {
                            Text(verbatim: choice.label)
                        }
                    }
                }
                Divider()
            }
            Toggle("Follow the Focused Terminal", isOn: followsFocus)
        } label: {
            HStack(spacing: 4) {
                if isPinned {
                    // The state has to be legible without opening the menu:
                    // it decides where the review is delivered, and the reader
                    // finding out at Insert is the case this exists to close.
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(LimpidColor.secondaryText)
                        .accessibilityHidden(true)
                }
                Text(verbatim: paneTitle)
                    .font(LimpidFont.caption)
                    .foregroundStyle(LimpidColor.secondaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(LimpidColor.tertiaryText)
            }
        }
        // `.button` rather than `.borderlessButton`: the borderless style
        // draws its own accent-colored indicator ahead of the label and
        // ignores `menuIndicator(.hidden)`, which put a blue chevron in
        // front of a heading that is otherwise quiet gray.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text("Choose Terminal"))
        .accessibilityValue(
            isPinned
                ? Text("Pinned to this terminal")
                : Text("Following the focused terminal")
        )
        .help(
            isPinned
                ? Text("Pinned to this terminal")
                : Text("Following the focused terminal")
        )
        .pointerOverHandle()
    }

    /// Whether the destination is still whatever the window focuses. Writing
    /// `false` pins what is docked now rather than asking which pane to pin —
    /// the reader turning following off means the terminal in front of them.
    private var followsFocus: Binding<Bool> {
        Binding(
            get: { !isPinned },
            set: { follows in
                guard follows else {
                    reviewPresentation.pinDestination(to: paneID)
                    return
                }
                let focused = session.activeTab?.splitTree.effectiveFocusedLeafID
                // Waking first, like every other path that mounts a pane
                // review had told libghostty to stop drawing.
                if let focused, focused != paneID {
                    reveal(focused)
                }
                reviewPresentation.followFocus(focused)
            }
        )
    }

    /// Move the tab's focus as well as review's destination. The pane docked
    /// under review is the one being worked in, and a pane the tab still
    /// considers unfocused is drawn at the unfocused-pane opacity — the
    /// terminal came back dimmed after every switch.
    private func select(_ paneID: UUID) {
        reveal(paneID)
        reviewPresentation.pinDestination(to: paneID)
        guard let tab = session.tab(containing: paneID) else { return }
        session.update(tab.id) { $0.splitTree.focusedLeafID = paneID }
    }

    private var resize: some Gesture {
        // Global coordinates, because the view carrying this gesture is the
        // one being moved. In its own space the origin travels with it, so
        // `translation` stopped matching the pointer after the first step and
        // the divider drifted away from the cursor.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                let origin = dragOrigin
                    ?? reviewPresentation.stripHeight(in: available)
                    ?? ReviewStrip.default
                dragOrigin = origin
                reviewPresentation.resizeStrip(to: origin - value.translation.height, in: available)
            }
            .onEnded { _ in dragOrigin = nil }
    }
}

/// The destination, as the leading half of the insert control. Review is
/// bound to the pane below it, so this reports where the text goes and what
/// is running there — it does not ask, and it does not refuse.
///
/// Also used with the ring of the accent it is drawn in: the dot alone says
/// whether there is a terminal, and the accent says this is where the insert
/// button acts.
struct ReviewDestinationChip: View {
    let destination: ReviewDestination?
    /// The probe spawns processes, so there is a moment after a pane switch
    /// where the answer is not known yet. Reporting that as "no terminal" told
    /// the reader something false about a pane that has one.
    var isResolving = false

    @Environment(\.limpidAccent) private var accent

    private var name: String {
        if let destination {
            return destination.title
        }
        return isResolving ? String(localized: "Checking…") : String(localized: "No terminal")
    }

    /// The command in front, when it adds anything. An agent pane is usually
    /// titled after its agent, and "claude · claude" says one thing twice.
    /// The dash for an unresolved command is not localized: it stands in for
    /// a command name, which we never translate either.
    private var status: String? {
        guard let destination else { return nil }
        guard let foreground = destination.foreground else { return "—" }
        return foreground == destination.title ? nil : foreground
    }

    private var summary: String {
        if let status {
            return name + " · " + status
        }
        return name
    }

    /// The one signal of whether there is somewhere to send to. The ring
    /// used to carry the same color, which said it twice.
    private var tint: Color {
        if destination != nil {
            return LimpidColor.success
        }
        return isResolving ? LimpidColor.warning : LimpidColor.error
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(verbatim: name)
                .font(LimpidFont.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            if let status {
                Text(verbatim: "·")
                    .font(LimpidFont.caption)
                    .foregroundStyle(LimpidColor.tertiaryText)
                // The name gives way first: a command is short and is the
                // half that says what the paste will land in.
                Text(verbatim: status)
                    .font(LimpidFont.caption.monospaced())
                    .foregroundStyle(LimpidColor.secondaryText)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, 9)
        // Fills whatever width it is given, and asks for no more than its
        // text: `WidthFloorLayout` in the header decides how far a long name
        // may be squeezed. Filling matters because a truncated line ends on
        // a character boundary, a few points short of the width it was
        // offered, and a fill sized to the text left that strip unpainted
        // beside the insert button.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: ReviewHeaderMetrics.controlHeight)
        // A plain block: the header clips and outlines it together with the
        // insert button, so any shape drawn here would show as a seam.
        .background(accent.opacity(0.12))
    }

    var body: some View {
        chip
            // A truncated name has no other way out. The text is not
            // selectable, so the tooltip is delivered here.
            .help(Text(verbatim: summary))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Review Destination"))
            .accessibilityValue(Text(verbatim: summary))
    }
}

private extension View {
    /// Give a control inside the strip header the plain pointer back.
    ///
    /// The header is itself the resize handle, including the two controls
    /// sitting in it. A nested pointer style keeps those controls from
    /// advertising a drag they do not answer.
    func pointerOverHandle() -> some View {
        pointerStyle(.default)
    }
}
