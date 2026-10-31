// SurfaceView+Drag.swift
// Weir — ⌥⌘+drag from a pane initiates an AppKit dragging session that
// the pane strip's tabs, the sidebar's rows, and the other panes catch: drop
// onto a tab merges the pane into that tab, onto a row moves it there, onto a
// pane swaps or splits it there. The modifier
// gate keeps ordinary text-selection drags untouched, and matches
// macOS's "explicit pickup" convention (⌘+drag in Finder, ⌥+drag for
// copies elsewhere).

import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let paneDragLog = Logger.weir("pane.drag")

/// What a pane's drag reads from around its surface as it starts: its tab
/// for the log, and the name and the person's accent on its chip.
struct PaneDragContext {
    let ownerTabID: () -> String
    let title: () -> String
    let accent: () -> Color
}

extension SurfaceView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Move semantics — the pane leaves its source tab when the drop
        // lands. SwiftUI's drop targets read `DropProposal(.move)` to
        // suppress the green "+" badge, so matching here keeps the cursor
        // badge consistent end-to-end.
        // `.copy` too: a pane's swap and split zones are each a
        // `.dropDestination` (`PaneSwapDropOverlay`), which proposes it.
        [.move, .copy]
    }

    /// ⌥⌘ is what picks a pane up and stays held through the drag. AppKit
    /// would otherwise narrow the operations above by those keys (⌥ to copy,
    /// ⌘ to generic), leaving nothing a drop target proposing `.move` can
    /// use, so the sidebar's rows would refuse the pane on release.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        // Reset the mouse-gate state. AppKit eats the matching `mouseUp`
        // for our `SurfaceView` in most cases (it lands on the drop
        // target instead, if anywhere) — without this clear,
        // `isAppKitPaneDragInProgress` would stay `true` and the next
        // ordinary drag's `mouseDragged` would silently skip
        // `sendMousePos`, stranding libghostty in a "button pressed
        // but never released" state and turning any later mouse
        // movement into a runaway selection.
        paneDragAnchor = nil
        isAppKitPaneDragInProgress = false
        // Belt-and-braces dragState teardown: SwiftUI's drop delegate
        // calls `dragState.end()` on every drop result, but if AppKit
        // ends the session without ever entering a SwiftUI drop target
        // (cursor released outside every drop target) the delegate never runs
        // and the hover state would linger. The mouse-up monitor in
        // WeirDragState handles the common case; this is the AppKit
        // mirror for safety.
        if dragState?.current == .pane {
            dragState?.end()
        }
    }

    /// Open an AppKit drag session that carries this pane's id to the
    /// pane strip's and the sidebar's drop targets. Called from `mouseDragged`
    /// once the cursor has moved far enough from the ⌥⌘-mouseDown anchor, and
    /// from a pane's header, where a plain drag picks the pane up (`PaneHeaderView`).
    func beginPaneDrag(with event: NSEvent) {
        guard let paneID, let dragState else { return }

        // Hand the pane strip's drop targets the same wire format the sidebar uses
        // (`<prefix>:<uuid>`). SwiftUI's `.dropDestination(for: String.self)`
        // matches pasteboard items conforming to `public.text`, so we
        // write both `public.utf8-plain-text` (`NSPasteboard.PasteboardType.string`)
        // AND `public.text` explicitly — the modern drop API is strict
        // about which identifier it inspects, and an AppKit-originated
        // drag whose pasteboard only carries the utf8 child type
        // sometimes fails to match the parent type SwiftUI registered
        // for. This was the intermittent "drag does nothing" we saw on
        // drops over tab rows.
        let payload = SidebarDragPayload(prefix: DragPrefix.pane, id: paneID.uuidString)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload.wire, forType: .string)
        pasteboardItem.setString(payload.wire, forType: NSPasteboard.PasteboardType(UTType.text.identifier))

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // A visible drag image is required: macOS 26 silently refuses to
        // begin a session when the snapshot is effectively invisible (the
        // same regression `weirDraggable` works around for sidebar rows).
        let chip = paneDragChip()
        let cursorPointInView = convert(event.locationInWindow, from: nil)
        // Below and to the right of the pointer, as a tab's chip is, so the
        // row it would land on stays readable.
        let gap = WeirLayout.Supervision.spaceXS
        let dragFrame = NSRect(
            x: cursorPointInView.x + gap,
            y: cursorPointInView.y - chip.size.height - gap,
            width: chip.size.width,
            height: chip.size.height
        )
        item.setDraggingFrame(dragFrame, contents: chip)

        dragState.begin(.pane, sourceID: paneID.uuidString)
        // Origin tab id (when wired) tells log readers which tab the
        // drag left. Surface dimensions help spot "drag that started at frame zero"
        // bugs without needing a screen recording.
        let originTab = paneDragContext?.ownerTabID() ?? "?"
        let viewSize = "\(Int(bounds.width))x\(Int(bounds.height))"
        let context = "pane=\(paneID.uuidString) tab=\(originTab) view=\(viewSize)"
        paneDragLog.debug("begin pane drag \(context, privacy: .public)")
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// The pane's name in the chip a dragged tab carries (`DragChipFace`),
    /// the name its header shows, so the person sees that this pane moves
    /// and not its whole tab. Renders under the source window's effective
    /// appearance, so the tokens resolve to the variant the person sees
    /// rather than the app's default.
    private func paneDragChip() -> NSImage {
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        var chip: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: DragChipFace(title: paneDragContext?.title() ?? "")
                .environment(\.weirAccent, paneDragContext?.accent() ?? WeirColor.defaultAccent)
                // A renderer resolves colors from its own environment, not
                // from the appearance drawn under.
                .environment(\.colorScheme, appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light))
            renderer.scale = window?.backingScaleFactor ?? 2
            chip = renderer.nsImage
        }
        // Never empty: macOS refuses to begin a drag from an invisible image.
        return chip ?? NSImage(size: WeirLayout.Supervision.dragPreviewMinSize)
    }

    // MARK: - Modifier-gated mouse interception

    /// `true` whenever the click is in one of the two phases that
    /// belong to a pane drag (anchor armed but not yet committed, or
    /// AppKit session in flight). In either case the press / release
    /// must NOT reach libghostty — we swallow it at this layer.
    var isCapturingMouseForPaneDrag: Bool {
        paneDragAnchor != nil || isAppKitPaneDragInProgress
    }

    /// Capture the cursor position when ⌥⌘ is held on mouseDown. The
    /// drag only opens once movement exceeds `paneDragThreshold`; until
    /// then we own the click and libghostty sees nothing.
    func armPaneDragAnchor(at locationInWindow: NSPoint) {
        paneDragAnchor = locationInWindow
        isAppKitPaneDragInProgress = false
    }

    /// Returns true when the cursor has moved far enough from the anchor
    /// to commit to a drag. Consumes the anchor.
    func crossedPaneDragThreshold(at locationInWindow: NSPoint) -> Bool {
        guard let anchor = paneDragAnchor else { return false }
        let dx = locationInWindow.x - anchor.x
        let dy = locationInWindow.y - anchor.y
        if abs(dx) + abs(dy) > paneDragThreshold {
            paneDragAnchor = nil
            isAppKitPaneDragInProgress = true
            return true
        }
        return false
    }

    /// Clear any pending drag-arm state when the mouse comes up without
    /// crossing the threshold (a stationary ⌥⌘-click).
    func discardPaneDragAnchor() {
        paneDragAnchor = nil
        isAppKitPaneDragInProgress = false
    }

    // MARK: - Cursor

    /// Swap the cursor to a plain arrow while ⌥⌘ are held over the
    /// pane, so the user gets a visual cue that the click would pick
    /// the pane up (instead of the I-beam we keep for selection during
    /// regular use). Restored to `currentCursor` once the modifiers
    /// drop. Mouse movement updates it directly; stationary modifier
    /// changes rebuild the surface's cursor rect in `flagsChanged`.
    func updatePaneDragCursor(_ event: NSEvent) {
        guard paneID != nil, dragState != nil else { return }
        let armed = event.modifierFlags.contains([.option, .command])
        let desired: NSCursor = armed ? .arrow : currentCursor
        // `NSCursor.set()` is idempotent — no flicker when the desired
        // cursor matches the active one, so we don't bother tracking
        // last-set state here.
        desired.set()
    }
}
