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
// listener + anchor tracker; the payload (`PRHoverCardContent`)
// renders the card; a shared `PRHoverPresentation` observable
// coordinates open/close timing so hand-offs between rows and the
// card body work without race conditions.
//
// The overlay is hoisted out of the slab because the card has to be
// drawn beside the sidebar, over the tab column — and the container
// slab is a sibling plane in `ThreePaneLayout`, not an ancestor of
// it. An overlay attached inside the slab would be composited within
// the slab's own plane and clipped with it.
//
// `ThreePaneLayout`'s own `ZStack` is the nearest scope that spans
// both planes; we go one level further out, to `ContentView`, so this
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
    @ViewBuilder
    func prHoverCard(_ target: (container: ContainerID, info: PRInfo)?) -> some View {
        if let target {
            modifier(PRHoverCardPresenter(info: target.info, rowID: target.container))
        } else {
            self
        }
    }
}

private struct PRHoverCardPresenter: ViewModifier {
    let info: PRInfo
    let rowID: ContainerID

    @Environment(PRHoverPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var anchorRect: CGRect = .zero

    func body(content: Content) -> some View {
        content
            // A .background(GeometryReader) captures the row's global
            // frame without changing its layout — the overlay in
            // ContentView needs it to position the card next to the
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
                        delay: reduceMotion ? .zero : LimpidLayout.prHoverCardOpenDelay
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
/// currently hovered row. Rendered by `ContentView` so it can escape
/// the sidebar column's clip bounds — see the file banner for why the
/// slab itself is the wrong place for it.
struct PRHoverCardHost: View {
    /// Read from the environment rather than passed in, so the call
    /// site matches its neighbors in `ContentView` (`ToastHost`,
    /// `WorktreeMoveSuggestionHost`) and the presenter modifier, which
    /// already reaches the same object that way.
    @Environment(PRHoverPresentation.self) private var presentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Gap between the sidebar row's right edge and the card's left
    /// edge, so the card reads as attached to the row without
    /// touching it.
    private let anchorGap: CGFloat = 12
    /// Corner radius of the card's material and its border, which have
    /// to be struck from the same value or the stroke sits off the
    /// fill's edge.
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

    var body: some View {
        GeometryReader { overlayGeo in
            if let snap = presentation.visible {
                let overlayOrigin = overlayGeo.frame(in: .global).origin
                let localX = snap.anchorRect.maxX - overlayOrigin.x + anchorGap
                let localY = snap.anchorRect.midY - overlayOrigin.y
                PRHoverCardContent(info: snap.info)
                    .background(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(.regularMaterial)
                            .pointerStyle(.default)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(LimpidColor.toolbarHairline, lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(0.20), radius: 12, x: 0, y: 4)
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
                    .transition(.opacity)
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
        .animation(
            // Shorter and unsprung under Reduce Motion rather than nothing:
            // the card appearing and disappearing with no transition at all
            // reads as a glitch, which is not what the setting asked for.
            // Same substitution the toast and the move suggestion make.
            reduceMotion ? nil : LimpidMotion.prHoverCard,
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            separator
            checksRow
            footer
        }
        .padding(14)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
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
            HStack(spacing: 8) {
                // Octicons, from the same family the row's mark is
                // drawn from, so the card and the row read as one
                // report rather than two vocabularies.
                //
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
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 8) {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Forge-specific noun here too, so a GitLab row never
                // reports "no checks" for a thing GitLab calls a
                // pipeline.
                Text("No \(String(localized: info.forge.checksNoun))")
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
                Label(
                    String(localized: "Open on \(info.forge.displayName)"),
                    systemImage: "arrow.up.right.square"
                )
            }
            .buttonStyle(.borderless)
            .pointerStyle(.link)
            Spacer()
        }
        .padding(.top, 2)
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
        case .success: LimpidColor.success
        case .failure: LimpidColor.error
        case .pending: LimpidColor.warning
        }
    }

    /// One sentence shape across both forges: "<noun> <verdict>",
    /// with the count breakdown in parentheses when the forge gives us
    /// one. The noun differs per forge on purpose — see
    /// `ForgeKind.checksNoun`.
    ///
    /// GitLab reports only an aggregate status, so `counts` is absent
    /// there and the verdict stands alone. Inventing "(0/0)" would
    /// read as a confident claim about checks we never saw.
    private func checksText(_ checks: PRChecks) -> Text {
        // Each branch is one complete sentence in the catalog rather
        // than fragments concatenated at runtime, so a translator sees
        // the whole phrase and can reorder it. `noun` arrives as an
        // already-localized String because it varies per forge.
        let noun = String(localized: info.forge.checksNoun)
        guard let counts = checks.counts else {
            return switch checks.conclusion {
            case .success: Text("\(noun) passed")
            case .failure: Text("\(noun) failed")
            case .pending: Text("\(noun) running")
            }
        }
        return switch checks.conclusion {
        case .success:
            Text("\(noun) passed (\(counts.passed)/\(counts.total))")
        case .failure:
            Text("\(noun) failed (\(counts.passed)/\(counts.total) passed)")
        case .pending:
            Text("\(noun) running (\(counts.passed)/\(counts.total) passed)")
        }
    }
}
