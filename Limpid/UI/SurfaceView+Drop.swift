// SurfaceView+Drop.swift
// Limpid — dropping files onto a pane types their shell-quoted paths.

import AppKit
import GhosttyKit

extension SurfaceView {
    /// `userInfo` key of `limpidMirrorFileDropRequested`: a `[URL]`.
    static let droppedFileURLsKey = "fileURLs"

    /// What the owning tab lets a drop do here. We read `TabCapabilities`
    /// rather than asking the surface how its bytes arrive, so the table
    /// stays the one place that decides. A view no tab has claimed yet
    /// takes nothing.
    private var dropCapabilities: TabCapabilities? {
        guard let capabilities = tabCapabilities?(), capabilities.canDropFile else { return nil }
        return capabilities
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard dropCapabilities != nil,
              sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: fileOnlyOptions)
        else {
            return []
        }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let capabilities = dropCapabilities,
              let urls = sender.draggingPasteboard.readObjects(
                  forClasses: [NSURL.self],
                  options: fileOnlyOptions
              ) as? [URL],
              !urls.isEmpty
        else { return false }

        // A mirror pane types the paths as a tmux paste, the route its
        // clipboard takes, so tmux brackets them exactly when the program
        // in the pane asked for bracketed paste.
        if capabilities.sendsInputThroughTmux {
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
