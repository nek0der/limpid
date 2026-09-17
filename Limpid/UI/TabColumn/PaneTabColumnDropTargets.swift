// PaneTabColumnDropTargets.swift
// Limpid — the two tab column drop targets that catch a ⌥⌘-dragged pane: drop
// onto a tab row merges the pane into that tab; drop onto the empty
// area below the list (or anywhere on the tab column body when there are no
// rows under the cursor) detaches the pane into a fresh sibling tab.

import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let paneDropLog = Logger.limpid("pane.drop")

extension View {
    /// Attach to a `TabRow` so dropping a ⌥⌘-dragged pane on it merges
    /// the pane into that tab.
    ///
    /// The drop catcher only renders while a pane drag is in flight, so
    /// `TabRow`'s existing `.tabReorderTarget` modifier (the legacy
    /// `onDrop(of:delegate:)` route used for tab reorder) still owns the
    /// drop area for tab drags — without that gate, SwiftUI's
    /// `.dropDestination` and the older `onDrop` modifier competed for
    /// drops on the same view and pane drops silently no-op'd. Paired
    /// with `UnifiedReorderDelegate.validateDrop` returning `false` for
    /// `.pane` drags, so the inner reorder modifier never consumes the
    /// drop even if SwiftUI's dispatch order ever changes.
    @MainActor
    func paneMergeDropTarget(
        targetTabID: UUID,
        session: WindowSession,
        dragState: LimpidDragState,
        highlightNamespace: Namespace.ID,
        sourceTabID: UUID?,
        pillHorizontalPadding: CGFloat = LimpidLayout.rowPillInset
    ) -> some View {
        overlay {
            if dragState.current == .pane {
                let isSourceRow = sourceTabID == targetTabID
                if isSourceRow {
                    // Cursor over the row the pane came from: refuse
                    // the drop via a delegate that returns
                    // `.forbidden`, so the cursor loses the green `+`
                    // (and no accent tint is painted). The merge would
                    // be a no-op anyway — `TabActions.mergePaneIntoTab`
                    // guards source == target — and falling through to
                    // the detach background catcher would create a
                    // stray new tab.
                    Color.clear
                        .contentShape(Rectangle())
                        .onDrop(of: [UTType.text], delegate: ForbidPaneDropDelegate())
                } else {
                    PaneMergeDropArea(
                        targetTabID: targetTabID,
                        sourceTabID: sourceTabID,
                        session: session,
                        dragState: dragState,
                        highlightNamespace: highlightNamespace,
                        pillHorizontalPadding: pillHorizontalPadding
                    )
                }
            }
        }
    }

    /// Attach to the tab column body so dropping a ⌥⌘-dragged pane on the empty
    /// area (or on the list when zero tabs are present) detaches the
    /// pane into a new tab. Renders BEHIND the modified view (via
    /// `.background`, not `.overlay`) so per-row merge catchers placed
    /// in front via `.overlay` on `TabRow` win for drops on a row — the
    /// detach catcher only sees drops on the empty space the rows
    /// don't cover.
    @MainActor
    func paneDetachDropTarget(
        container: ContainerID,
        session: WindowSession,
        dragState: LimpidDragState
    ) -> some View {
        background {
            if dragState.current == .pane {
                PaneDetachDropArea(
                    container: container,
                    session: session,
                    dragState: dragState
                )
            }
        }
    }

    /// Shared `.dropDestination(for: String.self)` body for the two
    /// pane-drag targets above. Lives in one place so the hover-state
    /// bookkeeping + `paneIDFromWire` parse stays consistent.
    @MainActor
    fileprivate func paneStringDropCatcher(
        key: String,
        dragState: LimpidDragState,
        perform: @escaping (UUID) -> Void
    ) -> some View {
        dropDestination(for: String.self) { strings, _ in
            for wire in strings {
                if let paneID = paneIDFromWire(wire) {
                    perform(paneID)
                    return true
                }
            }
            return false
        } isTargeted: { hovering in
            if hovering, dragState.current == .pane {
                dragState.hoverTargetID = key
            } else if dragState.hoverTargetID == key {
                dragState.hoverTargetID = nil
            }
        }
    }
}

/// Parse a `pane:<UUID>` wire payload back into a leaf id. Returns nil
/// for any other prefix (tab/group/project/worktree) so the same drop
/// target can silently ignore a stray sidebar drag that ends up on it —
/// `paneStringDropCatcher`'s `isTargeted` already filters by
/// `dragState.current == .pane`, this is a defense in depth against a
/// malformed pasteboard payload that slips through anyway.
private func paneIDFromWire(_ wire: String) -> UUID? {
    let prefix = "pane:"
    guard wire.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(wire.dropFirst(prefix.count)))
}

/// Hover-tinted merge zone painted on every non-source tab row while
/// a pane drag is in flight. Lifted out of the `paneMergeDropTarget`
/// modifier so the fill can read the user's chosen Limpid accent
/// (`\.limpidAccent`) instead of the OS-wide System Accent — the
/// modifier itself runs inside an `extension View` and so can't pull
/// environment values directly.
@MainActor
private struct PaneMergeDropArea: View {
    let targetTabID: UUID
    /// The tab the dragged pane comes from, `nil` when the drag did not
    /// record one.
    let sourceTabID: UUID?
    let session: WindowSession
    let dragState: LimpidDragState
    let highlightNamespace: Namespace.ID
    /// Inset the highlight to the same horizontal padding that
    /// `selectablePillBackground` paints the active pill with — the
    /// vertical tab column passes 10pt (default), the horizontal
    /// strip overrides to 0pt so the pill fills the column slot. Any
    /// mismatch reads as a misaligned drop target since the user has
    /// the active-pill shape memorized.
    let pillHorizontalPadding: CGFloat
    @Environment(\.limpidAccent) private var accent
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    /// Optional because the tab column is also built in previews and tests,
    /// which mount no toast center.
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?

    private var key: String {
        "pane-merge-\(targetTabID)"
    }

    /// Whether this row takes the dragged pane. A row that would refuse it
    /// is not lit and shows the "no drop" cursor, so the refusal is legible
    /// while the pane is still in the air; the drop is still caught, so a
    /// pane dropped anyway gets the word that says why rather than landing
    /// in a new tab behind the row. A drag without a known source is lit as
    /// before, and the drop decides.
    private var acceptsDraggedPane: Bool {
        guard let sourceTabID,
              let sourceTab = session.tab(sourceTabID),
              let targetTab = session.tab(targetTabID)
        else { return true }
        return TmuxMirrorActions.acceptsPane(from: sourceTab, into: targetTab)
    }

    /// Routed through the mirror-aware action rather than `TabActions`
    /// directly: two mirrors of one tmux session merge with `join-pane`, and
    /// any other pairing that involves a mirror is refused with a word to
    /// the user.
    private func merge(_ paneID: UUID) {
        paneDropLog.debug(
            "merge target=\(targetTabID.uuidString, privacy: .public) pane=\(paneID.uuidString, privacy: .public)"
        )
        TmuxMirrorActions.mergePaneIntoTab(
            session,
            paneID: paneID,
            into: targetTabID,
            store: tmuxStore,
            toastCenter: toastCenter
        )
    }

    var body: some View {
        ZStack {
            if acceptsDraggedPane {
                Color.clear
                    .contentShape(Rectangle())
                    .paneStringDropCatcher(key: key, dragState: dragState, perform: merge)
            } else {
                // The same delegate route the source row uses, so the cursor
                // says no before the drop instead of offering the green `+`
                // and taking it back with a toast afterwards.
                Color.clear
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [UTType.text],
                        delegate: RefusePaneDropDelegate(key: key, dragState: dragState, perform: merge)
                    )
            }
            // Single accent rectangle slides between rows via a shared
            // `matchedGeometryEffect` id, mirroring AppKit's drop
            // indicator glide.
            if dragState.hoverTargetID == key {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.20))
                    .padding(.horizontal, pillHorizontalPadding)
                    .matchedGeometryEffect(
                        id: "pane-merge-highlight",
                        in: highlightNamespace
                    )
                    .allowsHitTesting(false)
            }
        }
    }
}

/// The detach catcher, a view rather than a plain `Color` so it can read the
/// tmux store and the toast center: a pane dragged out of a mirror tab leaves
/// through `break-pane`, not through the ordinary tree surgery, and the
/// `extension View` modifier around it cannot pull environment values.
@MainActor
private struct PaneDetachDropArea: View {
    let container: ContainerID
    let session: WindowSession
    let dragState: LimpidDragState
    @Environment(\.tmuxConnectionStore) private var tmuxStore
    /// Optional for the same reason as `PaneMergeDropArea`'s.
    @Environment(ToastCenter.self) private var toastCenter: ToastCenter?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .paneStringDropCatcher(
                key: "pane-detach-\(container)",
                dragState: dragState
            ) { paneID in
                paneDropLog.debug("detach pane=\(paneID.uuidString, privacy: .public)")
                // Reuse the right-click path. The detach to new tab is
                // byte-identical between menu and drag; gating on multi-leaf
                // tabs is built into `movePaneToNewTab`.
                TmuxMirrorActions.movePaneToNewTab(
                    session,
                    paneID: paneID,
                    store: tmuxStore,
                    toastCenter: toastCenter
                )
            }
    }
}

/// Shows the macOS "no drop" cursor over a row that would refuse the pane,
/// and still hands a drop that arrives anyway to `perform`, which says why.
/// AppKit withholds the drop while the proposal is `.forbidden`, so in
/// practice the drag simply ends over the row; `perform` is kept for the
/// case where it is delivered, so the refusal is never silent twice.
@MainActor
private struct RefusePaneDropDelegate: DropDelegate {
    let key: String
    let dragState: LimpidDragState
    let perform: (UUID) -> Void

    /// The highlight is a single rectangle shared between rows, so a row
    /// that will not take the pane has to clear it as it takes the cursor —
    /// otherwise it stays lit on whichever row the pointer left.
    func dropEntered(info: DropInfo) {
        if dragState.hoverTargetID == key || dragState.current == .pane {
            dragState.hoverTargetID = nil
        }
    }

    func validateDrop(info: DropInfo) -> Bool {
        true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let wire = object as? String, let paneID = paneIDFromWire(wire) else { return }
            Task { @MainActor in perform(paneID) }
        }
        return true
    }
}

/// Refuses every drop with `.forbidden`. Mounted only on the source
/// pane's own tab row so dragging back onto it shows the macOS "no
/// drop" cursor instead of the green-plus `Copy` badge that
/// `.dropDestination` defaults to.
@MainActor
private struct ForbidPaneDropDelegate: DropDelegate {
    func validateDrop(info: DropInfo) -> Bool {
        false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        false
    }
}
