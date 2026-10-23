// PRHoverCard.swift
// Limpid — hover-revealed pull-request card, rendered as a scene-root
// SwiftUI overlay rather than through `.popover`.
//
// Why not `.popover`? With a popover open, clicking a row took two
// clicks to activate it: the first only dismissed the popover. That
// is a bad trade for a panel the user did not ask to open — it
// appears on hover, so every row it covers costs an extra click.
// AppKit documents neither the consumption nor the pass-through for
// any `NSPopover.Behavior`, so the observation is what we have, not
// a mechanism to design against.
//
// A plain SwiftUI overlay at scene root has no such behavior to
// depend on: clicks on the row reach their target directly, and only
// clicks landing ON the card's own rect are consumed — which is
// exactly what the link button it carries needs.
//
// The presenter modifier (`prHoverCard(_:)`) attaches the hover
// listener + anchor tracker to a view the card opens from as a whole (the
// header's chip). A sidebar row splits the two: the row is the
// anchor (`prHoverCardAnchor`), and only its mark and its second line's
// fact open the card (`prHoverCardPart`). The payload (`PRHoverCardContent`)
// renders the card; a shared `PRHoverPresentation` observable
// coordinates open/close timing so hand-offs between rows and the
// card body work without race conditions.
//
// The overlay is hoisted out of the sidebar because the card has to be
// drawn beside it, over the session area — a sibling plane, not a
// descendant. An overlay attached inside the sidebar would be composited
// within the sidebar's own plane and clipped with it.
//
// We host it at `WindowChromeHost`, which spans both planes, so this
// host sits with `ToastHost` and `WorktreeMoveSuggestionHost` rather
// than being the one floating layer declared somewhere else.

import AppKit
import SwiftUI

// MARK: - Presenter modifier

extension View {
    /// Attach a hover-revealed pull-request card to `self`. A nil
    /// `target` makes the modifier a no-op — no hover listener, no
    /// anchor tracking — so a row without a request behaves exactly
    /// as it did before this feature existed.
    /// `place` tells this place's card apart from another place's for the
    /// same branch.
    @ViewBuilder
    func prHoverCard(
        _ target: (container: ContainerID, info: PRInfo)?,
        place: PRHoverSource.Place = .row
    ) -> some View {
        if let target {
            modifier(PRHoverCardPresenter(info: target.info, rowID: PRHoverSource(container: target.container, place: place)))
        } else {
            self
        }
    }

    /// The view a sidebar row's card hangs beside, when the card opens
    /// from parts of it (`prHoverCardPart`). The rest of the view only
    /// holds an open card up while the pointer crosses it toward the card.
    /// Applied whether or not the row has a request, so the row keeps its
    /// identity, and its hover and rename state, as the request comes and
    /// goes.
    func prHoverCardAnchor(_ container: ContainerID?) -> some View {
        modifier(PRHoverCardAnchor(rowID: container.map { PRHoverSource(container: $0) }))
    }

    /// A part of a sidebar row that opens its card: the mark, or the
    /// second line while it states the request. A nil `target` makes the
    /// modifier a no-op.
    @ViewBuilder
    func prHoverCardPart(
        _ target: (container: ContainerID, info: PRInfo)?,
        part: PRHoverSource.Part
    ) -> some View {
        if let target {
            modifier(PRHoverCardPartPresenter(info: target.info, rowID: PRHoverSource(container: target.container), part: part))
        } else {
            self
        }
    }
}

/// Tracks a row's frame for the card its parts open, and holds that card
/// up while the pointer is on the row.
private struct PRHoverCardAnchor: ViewModifier {
    let rowID: PRHoverSource?

    @Environment(PRHoverPresentation.self) private var presentation
    /// Where the row is, whether it has a request yet, and whether the
    /// lazy list shows it, met in one place (`PRHoverAnchorReporter`).
    @State private var reporter = PRHoverAnchorReporter()

    func body(content: Content) -> some View {
        content
            // See `PRHoverCardPresenter` for why `initial: true`.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .global), initial: true) { _, new in
                            reporter.frameChanged(new, in: presentation)
                        }
                }
            )
            .onHover { hovering in
                if let rowID {
                    presentation.holdChanged(rowID: rowID, isHovering: hovering)
                }
            }
            // The request is often fetched after the row is laid out, when
            // the frame no longer changes to report it.
            .onChange(of: rowID, initial: true) { _, new in
                reporter.sourceChanged(to: new, in: presentation)
            }
            .onAppear { reporter.appeared(in: presentation) }
            .onDisappear { reporter.disappeared(in: presentation) }
    }
}

/// Opens a row's card from one of its parts, hung beside the row
/// (`PRHoverCardAnchor`) rather than beside the part.
private struct PRHoverCardPartPresenter: ViewModifier {
    let info: PRInfo
    let rowID: PRHoverSource
    let part: PRHoverSource.Part

    @Environment(PRHoverPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    presentation.rowEntered(
                        rowID: rowID,
                        part: part,
                        info: info,
                        anchor: nil,
                        delay: reduceMotion ? .zero : PRHoverPresentation.openDelay
                    )
                } else {
                    presentation.rowExited(rowID: rowID, part: part)
                }
            }
            // See `PRHoverCardPresenter`: a hovered part can leave without
            // `onHover(false)`, as the mark does when a state takes its place.
            .onDisappear {
                presentation.rowDisappeared(rowID: rowID, part: part)
            }
    }
}

private struct PRHoverCardPresenter: ViewModifier {
    let info: PRInfo
    let rowID: PRHoverSource

    @Environment(PRHoverPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchorRect: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // A .background(GeometryReader) captures the row's global
            // frame without changing its layout — the overlay in
            // WindowChromeHost needs it to position the card next to the
            // row wherever the row currently sits.
            //
            // `initial: true` matters: a row whose frame is settled by
            // the time this modifier is evaluated never produces a
            // change for `.onChange` to see, so the anchor would stay
            // at its `.zero` initial value for the life of the row.
            // The card then renders against the overlay's own origin
            // rather than beside the row it belongs to.
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.frame(in: .global), initial: true) { _, new in
                            anchorRect = new
                            presentation.updateAnchor(rowID: rowID, anchor: new)
                        }
                }
            )
            .onHover { hovering in
                if hovering {
                    presentation.rowEntered(
                        rowID: rowID,
                        info: info,
                        anchor: anchorRect,
                        delay: reduceMotion ? .zero : PRHoverPresentation.openDelay
                    )
                } else {
                    presentation.rowExited(rowID: rowID)
                }
            }
            // A hovered row can leave the hierarchy without ever
            // getting `onHover(false)` — the worktree is removed, a
            // refetch clears its PR, or the feature is switched off.
            // Telling the presentation explicitly is what keeps the
            // card from stranding on screen.
            .onDisappear {
                presentation.rowDisappeared(rowID: rowID)
            }
    }
}

// MARK: - Scene-root overlay

/// Hosts the floating PR card at scene root. Reads
/// `PRHoverPresentation.visible` and positions a card next to the
/// currently hovered row. Rendered by `WindowChromeHost` so it can escape
/// the sidebar column's clip bounds — see the file banner for why the
/// sidebar itself is the wrong place for it.
struct PRHoverCardHost: View {
    /// Read from the environment rather than passed in, so the call
    /// site matches its neighbors in `WindowChromeHost` (`ToastHost`,
    /// `WorktreeMoveSuggestionHost`) and the presenter modifier, which
    /// already reaches the same object that way.
    @Environment(PRHoverPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Gap between the sidebar row's right edge and the card's left
    /// edge, so the card reads as attached to the row without
    /// touching it.
    private let anchorGap: CGFloat = 12
    /// Corner radius of the card's floating surface.
    private let cornerRadius: CGFloat = 10
    /// Fixed card width, shared with `PRHoverCardContent` so the
    /// centering math below and the content's own frame cannot drift
    /// apart. Long titles wrap to two lines rather than widening it.
    private var cardWidth: CGFloat {
        PRHoverCardContent.width
    }

    /// Rough card height used only to keep the card inside the window
    /// near the top and bottom edges. An exact measurement would need
    /// a second layout pass; being a little conservative here costs
    /// nothing because the clamp only engages near the edges.
    private let approximateHeight: CGFloat = 150

    /// Keep the card's center far enough from the window edges that a
    /// row near the bottom of a long sidebar doesn't push it offscreen.
    private func clampedCenterY(_ proposed: CGFloat, in size: CGSize) -> CGFloat {
        let margin = approximateHeight / 2 + 8
        guard size.height > margin * 2 else { return proposed }
        return min(max(proposed, margin), size.height - margin)
    }

    /// Where the card starts: after its anchor, or before it when that
    /// would take it past the window's trailing edge (a chip near the
    /// window's right, where a sidebar row never is), and never past the
    /// leading edge.
    private func leadingX(of anchor: CGRect, in width: CGFloat) -> CGFloat {
        let after = anchor.maxX + anchorGap
        guard after + cardWidth > width - anchorGap else { return after }
        return max(anchorGap, anchor.minX - anchorGap - cardWidth)
    }

    var body: some View {
        GeometryReader { overlayGeo in
            if let snap = presentation.visible {
                let overlayOrigin = overlayGeo.frame(in: .global).origin
                let localX = leadingX(of: snap.anchorRect.offsetBy(dx: -overlayOrigin.x, dy: 0), in: overlayGeo.size.width)
                let localY = snap.anchorRect.midY - overlayOrigin.y
                PRHoverCardContent(info: snap.info)
                    .floatingPanelSurface(cornerRadius: cornerRadius)
                    .pointerStyle(.default)
                    .fixedSize(horizontal: false, vertical: true)
                    // `.onHover` MUST sit before `.position`. `.position`
                    // expands its subject to fill the parent (the whole
                    // window here), so a hover listener attached after it
                    // fires for every pointer move in the window — which
                    // pinned `cardIsHovering` true and stopped the
                    // card from ever dismissing. Same ordering keeps
                    // click-through intact: only the card's own rect
                    // swallows clicks.
                    .onHover { presentation.cardHoverChanged($0) }
                    .position(
                        x: localX + cardWidth / 2,
                        y: clampedCenterY(localY, in: overlayGeo.size)
                    )
                    .modalTransition(.floatingPanel, reduceMotion: reduceMotion)
                    .id(snap.rowID)
            }
        }
        // GeometryReader draws no content in its empty regions, so
        // SwiftUI hit-testing passes through them to the sidebar /
        // main content underneath — that's exactly the click-through
        // behavior NSPopover couldn't give us. Only the card's own
        // rect intercepts clicks.
        //
        // Animate on identity, not on the whole snapshot: `anchorRect`
        // changes on every scroll frame, and animating that makes the
        // card lag behind the row it belongs to.
        //
        // The fade stays under Reduce Motion: the card appearing and
        // disappearing with no transition at all reads as a glitch, which
        // is not what the setting asked for (`ModalMotion`).
        .animation(
            ModalMotion.floatingPanel.animation(reduceMotion: reduceMotion),
            value: presentation.visible?.rowID
        )
        .ignoresSafeArea()
    }
}

// MARK: - Card body

/// Card body. Split out from the presenter so the presenter stays
/// focused on hover orchestration and the payload stays focused on
/// layout — easier to iterate either half without disturbing the
/// other.
struct PRHoverCardContent: View {
    /// Card width. Referenced by `PRHoverCardHost` when positioning.
    static let width: CGFloat = 280

    let info: PRInfo

    /// The user's Limpid accent, not `Color.accentColor` — see
    /// `PRMarkPresentation` for why the OS constant is the wrong source.
    @Environment(\.limpidAccent) private var limpidAccent
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceS) {
            header
            separator
            checksRow
            footer
        }
        .padding(LimpidLayout.Supervision.spaceM)
        .frame(width: Self.width, alignment: .leading)
    }

    // MARK: - Sections

    /// `Divider()` resolves to `NSColor.separatorColor`, which is
    /// tuned for opaque surfaces and reads as a dark scratch across
    /// the card's translucent material. Deriving the rule from
    /// `.primary` instead makes it a light hairline in dark mode and a
    /// soft dark one in light mode, and matches the card's own border.
    private var separator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 0.5)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: LimpidLayout.Supervision.spaceSnug) {
            HStack(spacing: LimpidLayout.Supervision.spaceSnug) {
                // `Text("#\(info.number)")` would route through
                // LocalizedStringKey interpolation, which applies the
                // locale's grouping separator — turning merge request
                // 3850 into "#3,850". Identifiers are not quantities,
                // so we format the digits ourselves and skip the
                // catalog entirely.
                Text(verbatim: "#\(info.number)")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.secondary)
                Text(stateBadgeResource)
                    .font(.caption)
                    .padding(.horizontal, LimpidLayout.Supervision.spaceSnug)
                    .padding(.vertical, LimpidLayout.Supervision.spaceHairline)
                    .background(stateAccent.opacity(0.18), in: .capsule)
                    .foregroundStyle(stateAccent)
                Spacer(minLength: 0)
            }
            Text(info.title)
                .font(.system(.body, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private var checksRow: some View {
        if let checks = info.checks {
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                // Hidden from VoiceOver: `checksText` beside it already
                // states the conclusion, and an unlabeled `Image` is
                // announced by its asset name ("x-circle-fill").
                Image(checksIcon(checks))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(
                        width: LimpidLayout.prCardGlyphSize,
                        height: LimpidLayout.prCardGlyphSize
                    )
                    .foregroundStyle(checksColor(checks))
                    .accessibilityHidden(true)
                checksText(checks)
                    .font(.callout)
                    .accessibilityLabel(Text(verbatim: PRChecksText.spoken(checks, forge: info.forge, locale: locale)))
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: LimpidLayout.Supervision.spaceS) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Forge-specific noun here too, so a GitLab row never
                // reports "no checks" for a thing GitLab calls a
                // pipeline.
                Text("No \(info.forge.checksNoun)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(info.url)
            } label: {
                // The forge name is interpolated rather than baked
                // into two catalog entries so a third forge doesn't
                // need a new translation round — and so a GitLab user
                // is never told to "open on GitHub".
                Label {
                    Text("Open on \(info.forge.displayName)")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            Spacer()
        }
        .padding(.top, LimpidLayout.Supervision.spaceHairline)
    }

    // MARK: - Label helpers

    /// State badge text uses distinct catalog keys so the ja
    /// translation can be "オープン" (PR state) rather than reusing
    /// the existing "Open" entry which translates as "開く" (verb).
    /// `LocalizedStringResource` lets us keep "Open" as the English
    /// surface while routing through a unique catalog key.
    private var stateBadgeResource: LocalizedStringResource {
        if info.isDraft {
            return LocalizedStringResource("pr.state.draft", defaultValue: "Draft")
        }
        switch info.state {
        case .open:
            return LocalizedStringResource("pr.state.open", defaultValue: "Open")
        case .merged:
            return LocalizedStringResource("pr.state.merged", defaultValue: "Merged")
        case .closed:
            return LocalizedStringResource("pr.state.closed", defaultValue: "Closed")
        }
    }

    private var stateAccent: Color {
        if info.isDraft {
            return .secondary
        }
        switch info.state {
        case .open: return limpidAccent
        case .merged: return LimpidColor.merged
        case .closed: return .secondary
        }
    }

    /// Asset-catalog names, not SF Symbols. A run in progress gets the
    /// plain dot both forges use for the same state, rather than a
    /// clock — the point is "not settled yet", not elapsed time.
    private func checksIcon(_ checks: PRChecks) -> String {
        switch checks.conclusion {
        case .success: "check-circle-fill"
        case .failure: "x-circle-fill"
        case .pending: "dot-fill"
        }
    }

    private func checksColor(_ checks: PRChecks) -> Color {
        switch checks.conclusion {
        // A check's result, not a state, so a pass may be green; a
        // failure is the stopped red, since both are failures.
        case .success: SupervisionTokens.added.color
        case .failure: SupervisionTokens.stopped.color
        case .pending: SupervisionTokens.waiting.color
        }
    }

    /// The sentence a session row's VoiceOver label reads in words
    /// (`PRChecksText.spoken`), with its counts as the card shows them.
    private func checksText(_ checks: PRChecks) -> Text {
        Text(verbatim: PRChecksText.make(checks, forge: info.forge, locale: locale))
    }
}
