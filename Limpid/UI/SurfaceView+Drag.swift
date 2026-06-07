// SurfaceView+Drag.swift
// Limpid — ⌥⌘+drag from a pane initiates an AppKit dragging session that
// the tab list catches: drop onto a tab row merges the pane into that
// tab, drop onto the empty area detaches it into a new tab. The modifier
// gate keeps ordinary text-selection drags untouched, and matches
// macOS's "explicit pickup" convention (⌘+drag in Finder, ⌥+drag for
// copies elsewhere).

import AppKit
import OSLog
import UniformTypeIdentifiers

private let paneDragLog = Logger.limpid("pane.drag")

extension SurfaceView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // Move semantics — the pane leaves its source tab when the drop
        // lands. SwiftUI's drop targets read `DropProposal(.move)` to
        // suppress the green "+" badge, so matching here keeps the cursor
        // toolbar consistent end-to-end.
        .move
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
        // (cursor released outside tab column entirely) the delegate never runs
        // and the hover state would linger. The mouse-up monitor in
        // LimpidDragState handles the common case; this is the AppKit
        // mirror for safety.
        if dragState?.current == .pane {
            dragState?.end()
        }
    }

    /// Open an AppKit drag session that carries this pane's id to the
    /// tab column drop targets. Called from `mouseDragged` once the cursor has
    /// moved far enough from the ⌥⌘-mouseDown anchor.
    func beginPaneDrag(with event: NSEvent) {
        guard let paneID, let dragState else { return }

        // Hand the tab column drop targets the same wire format the sidebar uses
        // (`<prefix>:<uuid>`). SwiftUI's `.dropDestination(for: String.self)`
        // matches pasteboard items conforming to `public.text`, so we
        // write both `public.utf8-plain-text` (`NSPasteboard.PasteboardType.string`)
        // AND `public.text` explicitly — the modern drop API is strict
        // about which identifier it inspects, and an AppKit-originated
        // drag whose pasteboard only carries the utf8 child type
        // sometimes fails to match the parent type SwiftUI registered
        // for. This was the intermittent "drag does nothing" we saw on
        // drops over tab rows.
        let payload = SidebarDragPayload(prefix: "pane:", id: paneID.uuidString)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(payload.wire, forType: .string)
        pasteboardItem.setString(payload.wire, forType: NSPasteboard.PasteboardType(UTType.text.identifier))

        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        // A visible drag image is required — macOS 26 silently refuses
        // to begin a session when the snapshot is effectively invisible
        // (the same regression `limpidDraggable` works around for
        // sidebar rows). The chip is intentionally generic (the
        // system terminal glyph) rather than carrying the tab title,
        // since the pane the user picked up is one of several inside
        // that tab — labeling the chip with the tab name would
        // falsely suggest the whole tab is being moved.
        let chip = paneDragChip()
        let cursorPointInView = convert(event.locationInWindow, from: nil)
        let dragFrame = NSRect(
            x: cursorPointInView.x - chip.size.width / 2,
            y: cursorPointInView.y - chip.size.height / 2,
            width: chip.size.width,
            height: chip.size.height
        )
        item.setDraggingFrame(dragFrame, contents: chip)

        dragState.begin(.pane, sourceID: paneID.uuidString)
        // Origin tab id (when wired) gives log readers a way to
        // correlate this drag-start with the matching `paneDropLog`
        // event from `PaneTabColumnDropTargets.performDrop`. Surface
        // dimensions help spot "drag that started at frame zero"
        // bugs without needing a screen recording.
        let originTab = ownerTabIDForLogging?() ?? "?"
        let viewSize = "\(Int(bounds.width))x\(Int(bounds.height))"
        let context = "pane=\(paneID.uuidString) tab=\(originTab) view=\(viewSize)"
        paneDragLog.debug("begin pane drag \(context, privacy: .public)")
        beginDraggingSession(with: [item], event: event, source: self)
    }

    /// Compact rounded-square chip with the system terminal glyph.
    /// Reads as "you're carrying a terminal pane" without overclaiming
    /// about which tab or what's inside — snapshotting the live
    /// terminal would render blank on the Metal-backed surface anyway,
    /// and the chip is meant as a cursor companion, not a full preview.
    ///
    /// Renders under the source window's effective appearance so the
    /// pill background, stroke, and glyph all pick up the right
    /// light / dark variant of `NSColor.windowBackgroundColor`,
    /// `.separatorColor`, and `.labelColor`. Without the explicit
    /// `performAsCurrentDrawingAppearance` call, `NSImage.lockFocus`
    /// may resolve semantic colors against the app's default appearance
    /// rather than the window the user actually sees.
    private func paneDragChip() -> NSImage {
        let size = NSSize(width: 40, height: 40)
        let image = NSImage(size: size)
        let appearance = window?.effectiveAppearance ?? NSApp.effectiveAppearance
        image.lockFocus()
        defer { image.unlockFocus() }
        appearance.performAsCurrentDrawingAppearance {
            let rect = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
            NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            // `paletteColors` applies `.labelColor` directly to the
            // symbol's strokes — cleaner than `setFill` + template
            // tricks, and the color resolves under
            // `performAsCurrentDrawingAppearance` above.
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.labelColor]))
            if let symbol = NSImage(
                systemSymbolName: "apple.terminal",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?
                .withSymbolConfiguration(config)
            {
                let glyphRect = NSRect(
                    x: (size.width - symbol.size.width) / 2,
                    y: (size.height - symbol.size.height) / 2,
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                symbol.draw(in: glyphRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
        }
        return image
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
    /// drop. Called from `flagsChanged` and `mouseMoved` so press,
    /// release, and re-enter all keep the cursor in sync.
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
