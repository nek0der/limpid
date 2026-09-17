// SurfaceView+Drop.swift
// Limpid — dropping files onto a pane types their shell-quoted paths.

import AppKit
import GhosttyKit

extension SurfaceView {
    /// `userInfo` key of `limpidMirrorFileDropRequested`: a `[URL]`.
    static let droppedFileURLsKey = "fileURLs"

    /// How a file drop on this pane is typed, or `nil` when the tab takes no
    /// drop at all.
    enum FileDropRoute: Equatable {
        /// Typed into the surface by libghostty, as a pty-backed pane types
        /// anything else.
        case surfaceText
        /// Handed to tmux as a paste buffer, so tmux decides the bracketing.
        case tmuxPaste
    }

    /// What the owning tab lets a drop do here. We read `TabCapabilities`
    /// rather than asking the surface how its bytes arrive, so the table
    /// stays the one place that decides. A view no tab has claimed yet
    /// takes nothing.
    static func fileDropRoute(_ capabilities: TabCapabilities?) -> FileDropRoute? {
        guard let capabilities, capabilities.canDropFile else { return nil }
        return capabilities.sendsInputThroughTmux ? .tmuxPaste : .surfaceText
    }

    private var dropRoute: FileDropRoute? {
        Self.fileDropRoute(tabCapabilities?())
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropRoute != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: fileOnlyOptions)
        else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let route = dropRoute,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: fileOnlyOptions
              ) as? [URL],
              !urls.isEmpty
        else { return false }

        // A mirror pane types the paths as a tmux paste, the route its
        // clipboard takes, so tmux brackets them exactly when the program
        // in the pane asked for bracketed paste.
        if route == .tmuxPaste {
            NotificationCenter.default.post(
                name: .limpidMirrorFileDropRequested,
                object: self,
                userInfo: [Self.droppedFileURLsKey: urls]
            )
            return true
        }
        guard let surface else { return false }
        FileDropText.text(for: urls).withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
        return true
    }

    private var fileOnlyOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true]
    }
}
