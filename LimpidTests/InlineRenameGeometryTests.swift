// InlineRenameGeometryTests.swift
// Limpid — an inline rename's field stands exactly on its label: the same frame and glyphs, and past them only its well and fade.

import AppKit
import SwiftUI
import Testing
@testable import Limpid

@MainActor
@Suite("InlineRenameField geometry", .hostsWindows)
struct InlineRenameGeometryTests {
    /// How far into the window the label starts, past a white gutter that
    /// stands for the badge or glyph beside it.
    private static let gutter: CGFloat = 20
    private static let font = Font.system(size: 13, weight: .medium)
    /// The scale the glyphs are drawn at to be measured, whatever the
    /// display the tests run on, so the antialiasing reads alike on every
    /// screen. Where the glyphs are placed is still rounded to the window's
    /// own pixels (`Ink.devicePixel`).
    private static let measuringScale: CGFloat = 2
    /// How long a hosted field may take to mount and take the keyboard. A
    /// wait on a condition, so a quick machine does not wait it out; long
    /// enough that a run loaded by parallel suites still gets there.
    private static let timeout: Duration = .seconds(10)

    // MARK: - The frame

    /// The field stands on the label's frame, and a row that cut the label
    /// keeps that width while it is edited: only a label given
    /// `editingWidthLimit` takes more.
    @Test(arguments: [("feature-login", CGFloat?.none), ("a-workspace-name-long-enough-to-be-cut", 60)])
    func editingFrame_equalsLabelFrame(name: String, offered: CGFloat?) async throws {
        let atRest = try await labelFrame(name: name, isEditing: false, offered: offered)
        let editing = try await labelFrame(name: name, isEditing: true, offered: offered)
        if let offered {
            #expect(atRest.width <= offered)
        }
        #expect(editing == atRest)
    }

    /// A tab's title the strip had cut opens for editing at its full width,
    /// or as wide as the same title at rest within the limit.
    @Test func editingFrame_withWidthLimit_takesTheDraftsWidthUpToIt() async throws {
        let name = "feature-login"
        let full = try await labelFrame(name: name, isEditing: false)
        let unlimited = try await labelFrame(name: name, isEditing: true, offered: 40, editingWidthLimit: 500)
        let limited = try await labelFrame(name: name, isEditing: true, offered: 40, editingWidthLimit: 50)
        let atLimit = try await labelFrame(name: name, isEditing: false, offered: 50)
        #expect(full.width > 50)
        #expect(unlimited.width == full.width)
        #expect(limited.width == atLimit.width)
        #expect(limited.width > 40)
    }

    /// An emptied field keeps a place for its caret.
    @Test func editingFrame_emptyName_keepsRoomForTheCaret() async throws {
        let editing = try await labelFrame(name: "", isEditing: true)
        #expect(editing.width >= InlineRenameEditingStyle.caretAllowance)
    }

    /// A label never narrows as its edit opens: every frame it is laid out
    /// at from rest to the open field is at least as wide as at rest, and
    /// one given `editingWidthLimit`, as a tab is, only widens. The field
    /// mounts a pass after the edit opens and seeds its draft then, and a
    /// label that drew the draft at once was laid out at its caret's width
    /// for that pass, the jump a tab made as it was double-clicked.
    @Test(arguments: [
        ("feature-login", CGFloat?.none, CGFloat?.none),
        ("a-workspace-name-long-enough-to-be-cut", 60, nil),
        ("a-tab-title-the-strip-cut-to-share-its-width", 60, 400),
        ("", nil, nil)
    ])
    func openingAnEdit_neverNarrowsTheLabel(name: String, offered: CGFloat?, editingWidthLimit: CGFloat?) async throws {
        let model = EditingModel()
        let recorder = FrameHistory()
        let label = EditingHost(model: model, name: name, font: Self.font, editingWidthLimit: editingWidthLimit)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { recorder.widths.append($0) }
        let view = HStack(spacing: 0) {
            Color.white.frame(width: Self.gutter)
            if let offered {
                // As a cramped row or a crowded strip offers it.
                label.frame(maxWidth: offered, alignment: .leading)
            } else {
                label
            }
            Spacer(minLength: 0)
        }
        let (window, host) = Self.hosted(view)
        defer { window.close() }
        let atRest = try #require(await settledValue(in: host, timeout: Self.timeout) { recorder.widths.last })
        // Only the widths from here on: a label that keeps its width reports
        // none, so the open width falls back to the one at rest.
        let opensAt = recorder.widths.count
        model.isEditing = true
        await settle(host, timeout: Self.timeout) { Self.textField(in: host) != nil }
        #expect(Self.textField(in: host) != nil)
        let open = try #require(await settledValue(in: host, timeout: Self.timeout) { recorder.widths.last })
        let opening = Array(recorder.widths[opensAt...])
        #expect(opening.allSatisfy { $0 >= atRest })
        // Widening to the limit goes one way: no pass narrows on the way.
        #expect(zip(opening, opening.dropFirst()).allSatisfy { $1 >= $0 })
        #expect(open >= atRest)
        // With no limit to widen to and a name to draw, the open field
        // keeps the label's width exactly.
        if editingWidthLimit == nil, !name.isEmpty {
            #expect(open == atRest)
        }
    }

    // MARK: - The outsets

    /// The well stands under the open field from the leading outset to the
    /// trailing one, and nowhere else: it gives the selection and the first
    /// glyph room without reaching what stands beside the label.
    @Test func editingWell_spansTheLabelAndItsOutsets() async throws {
        let style = InlineRenameEditingStyle.inline
        let profile = try #require(await darkness(name: "feature-login", caret: .end))
        let atRest = try #require(await darkness(name: "feature-login", caret: nil))
        let label = try await labelFrame(name: "feature-login", isEditing: true)
        let wellStart = Self.gutter - style.leadingOutset
        let wellEnd = Self.gutter + label.width + style.trailingOutset
        // Tinted, not white, just inside either end of the well.
        #expect(profile.at(wellStart + 0.5) > 0.01)
        #expect(profile.at(wellEnd - 1) > 0.01)
        // White a pixel past either end.
        #expect(profile.at(wellStart - 1) < 0.01)
        #expect(profile.at(wellEnd + 0.5) < 0.01)
        // At rest there is no well.
        #expect(atRest.at(wellStart + 0.5) < 0.01)
    }

    /// A name longer than its frame, opened with the caret at its start as
    /// an edit opens (scrolled fully left), runs on past the trailing edge,
    /// and fades out there instead of being cut through a glyph: just
    /// inside the outset's end hardly anything is drawn, though the glyphs
    /// run solid across the frame's own edge. A row of dashes puts ink in
    /// every column, so a cut anywhere would show.
    @Test func editingField_overflowing_fadesAtTheTrailingEdge() async throws {
        let style = InlineRenameEditingStyle.inline
        let profile = try #require(await darkness(name: Self.dashes, caret: .start, offered: 60))
        // The label cut to fit takes a little less than it is offered.
        let label = try await labelFrame(name: Self.dashes, isEditing: true, offered: 60)
        let edge = Self.gutter + label.width
        // Solid up to the frame's edge and through the caret's width.
        #expect(profile.at(edge - 1) > 0.6)
        #expect(profile.at(edge + InlineRenameEditingStyle.caretWidth - 0.5) > 0.6)
        // Fading across the rest of the outset, to nearly nothing at its end.
        #expect(profile.at(edge + style.trailingOutset - 0.5) < 0.3)
        #expect(profile.at(edge + style.trailingOutset - 0.5) < profile.at(edge + 1.5))
        // And nothing past it.
        #expect(profile.at(edge + style.trailingOutset + 0.5) < 0.01)
    }

    /// Scrolled to its end, the same name runs on before the leading edge
    /// into the outset, fading out, and never as far as the gutter beside
    /// it that stands for the badge.
    @Test func editingField_scrolledToItsEnd_fadesAtTheLeadingEdge() async throws {
        let style = InlineRenameEditingStyle.inline
        let profile = try #require(await darkness(name: Self.dashes, caret: .end, offered: 60))
        let edge = Self.gutter
        #expect(profile.at(edge + 0.5) > 0.6)
        #expect(profile.at(edge - 1) > 0.01)
        #expect(profile.at(edge - style.leadingOutset + 0.5) < profile.at(edge - 1))
        #expect(profile.at(edge - style.leadingOutset - 0.5) < 0.01)
    }

    // MARK: - The glyphs

    /// The editing field's first and last glyphs stand where the label's
    /// do, to one pixel of the screen they are laid out for, so nothing
    /// moves as an edit begins: a 2x screen places them to half a point, a
    /// 1x one (a CI runner's) to a whole point, and a pixel is as close as
    /// either can show. The caret is put at the end, the furthest it can
    /// push the text, and with no selection drawn the dark pixels are the
    /// glyphs alone.
    @Test(arguments: ["feature-login", "HHHHHHHH", "~/projects/limpid"])
    func editingGlyphs_standOnTheLabels(name: String) async throws {
        let atRest = try #require(await inkColumns(name: name, isEditing: false))
        let editing = try #require(await inkColumns(name: name, isEditing: true))
        let onePixel = max(atRest.devicePixel, editing.devicePixel, 1 / Self.measuringScale)
        #expect(abs(editing.first - atRest.first) <= onePixel)
        #expect(abs(editing.last - atRest.last) <= onePixel)
    }

    /// A name longer than its frame scrolls inside it as the caret goes to
    /// its end, and the glyphs scrolled out stay inside the label's frame
    /// and its outsets rather than running over what stands beside it:
    /// unclipped, the field editor draws them up to 5pt before the frame.
    @Test func editingField_scrolled_isClippedToTheOutsets() async throws {
        let style = InlineRenameEditingStyle.inline
        let width: CGFloat = 60
        let ink = try #require(await inkColumns(
            name: "a-workspace-name-long-enough-to-scroll",
            isEditing: true,
            offered: width
        ))
        #expect(ink.first >= Self.gutter - style.leadingOutset)
        #expect(ink.last <= Self.gutter + width + style.trailingOutset)
    }

    // MARK: - A row's label, longer than the row

    /// A sidebar row's name fills the row and is cut to it, so the field
    /// opened on it scrolls, where a tab's title, opened at its full width,
    /// mostly does not. Opened as an edit opens, selected and scrolled to
    /// its start, its first glyph is drawn where the label's is, at the tab's
    /// size and the row's. The scroll to the start would stop the clip's
    /// slack (3pt) short, and TextKit 2 sets a scrolling text back by its
    /// line fragment padding (2pt), which together would stand the glyph up
    /// to 5pt before the label's, under the leading fade with its caret cut
    /// in half (`InlineRenameEditorAlignment`).
    @Test(arguments: [CGFloat(11.5), 13])
    func editingGlyphs_rowCutToFit_openedAtItsStart_standOnTheLabels(size: CGFloat) async throws {
        let name = "Use the Write tool to create new-approval-notes.md"
        let font = Font.system(size: size, weight: .medium)
        let atRest = try #require(await inkColumns(name: name, caret: nil, offered: 120, fillsWidth: true, font: font))
        let editing = try #require(await inkColumns(name: name, caret: .start, offered: 120, fillsWidth: true, font: font))
        let onePixel = max(atRest.devicePixel, editing.devicePixel, 1 / Self.measuringScale)
        #expect(abs(editing.first - atRest.first) <= onePixel)
    }

    /// The caret at the start of the name, a scrolling one or one that fits,
    /// at the tab's size and the row's: it stands on the label's leading
    /// edge, and everything that bounds its drawing reaches at least half a
    /// caret before that edge, the field editor (whose content views clip
    /// to it), the field editor's clip view, and the mask, solid there with
    /// nothing scrolled out. The system's caret is about 2pt wide, centered
    /// on its spot (read from screenshots of the app on macOS 26), so half
    /// of it falls before the edge. Read from the views rather than from pixels: a
    /// window that is never key draws no caret.
    @Test(arguments: [
        (CGFloat(11.5), "…/demo-repos", false),
        (CGFloat(13), "feature-login", false),
        (CGFloat(11.5), "Use the Write tool to create new-approval-notes.md", true),
        (CGFloat(13), "Use the Write tool to create new-approval-notes.md", true)
    ])
    func caretAtTheStart_hasRoomForItsLeadingHalf(size: CGFloat, name: String, isRowCutToFit: Bool) async throws {
        let caretHalfWidth: CGFloat = 1
        let extents = try #require(await caretExtents(
            name: name,
            caret: .caretAtStart,
            rowWidth: isRowCutToFit ? 120 : nil,
            font: .system(size: size, weight: .medium)
        ))
        #expect(abs(extents.caretX - Self.gutter) <= 1 / Self.measuringScale)
        #expect(extents.editorMinX <= extents.caretX - caretHalfWidth)
        #expect(extents.clipMinX <= extents.caretX - caretHalfWidth)
        #expect(InlineRenameEditingStyle.inline.leadingOutset >= caretHalfWidth)
    }

    /// Scrolled to its end, a row's name is laid before the label, which the
    /// alignment leaves alone, and the glyphs run into the outset, fading,
    /// never as far as the gutter.
    @Test func editingField_rowCutToFit_scrolledToItsEnd_fadesAtTheLeadingEdge() async throws {
        let style = InlineRenameEditingStyle.inline
        let atEnd = try #require(await darkness(name: Self.dashes, caret: .end, offered: 60, fillsWidth: true))
        #expect(atEnd.at(Self.gutter - 1) > 0.1)
        #expect(atEnd.at(Self.gutter - style.leadingOutset - 0.5) < 0.01)
    }

    // MARK: - The caret on an edge

    /// Where the caret stands, the mask lets it through whole: the leading
    /// outset is solid while no text is scrolled out before the label, so a
    /// caret at the start, which the system draws reaching into the outset,
    /// is not dimmed, and it fades only once text is scrolled out there. The
    /// trailing outset keeps the caret's width solid either way. A black
    /// block masked as the field is stands for whatever the field draws.
    @Test func mask_letsTheCaretThroughWhereNothingIsScrolledOut() async throws {
        let style = InlineRenameEditingStyle.inline
        let width: CGFloat = 60
        let start = Self.gutter
        let end = Self.gutter + width
        let atRest = try #require(await maskedBlock(width: width, overflow: .init(hasLeadingOverflow: false, hasTrailingOverflow: false)))
        let scrolled = try #require(await maskedBlock(width: width, overflow: .both))
        // Nothing scrolled out: both outsets solid, the caret's spot included.
        #expect(atRest.at(start - 1) > 0.95)
        #expect(atRest.at(start - style.leadingOutset + 0.5) > 0.95)
        #expect(atRest.at(end + 0.5) > 0.95)
        #expect(atRest.at(end + style.trailingOutset - 0.5) > 0.95)
        // Scrolled out on both sides: the outsets fade, and the trailing
        // caret's width stays solid.
        #expect(scrolled.at(start - style.leadingOutset + 0.5) < 0.6)
        #expect(scrolled.at(end + 0.5) > 0.95)
        #expect(scrolled.at(end + style.trailingOutset - 0.5) < 0.3)
        // Past the outsets nothing, either way.
        #expect(atRest.at(start - style.leadingOutset - 0.5) < 0.01)
        #expect(atRest.at(end + style.trailingOutset + 0.5) < 0.01)
    }

    // MARK: - Helpers

    /// Opens an edit from outside the field, as the strip does for a tab.
    /// Internal rather than private: the `@Observable` macro cannot reach
    /// a private nested class.
    @MainActor
    @Observable
    final class EditingModel {
        var isEditing = false
    }

    /// Every width a label is laid out at, in order.
    @MainActor
    private final class FrameHistory {
        var widths: [CGFloat] = []
    }

    private struct EditingHost: View {
        @Bindable var model: EditingModel
        let name: String
        let font: Font
        let editingWidthLimit: CGFloat?

        var body: some View {
            InlineRenameField(
                name: name,
                isEditing: $model.isEditing,
                font: font,
                foregroundColor: .black,
                onRename: { _ in },
                fillsWidth: false,
                editingWidthLimit: editingWidthLimit
            )
        }
    }

    /// Where the hosted label or field draws ink: its first and last
    /// columns, in points from the window's leading edge.
    private struct Ink: Equatable {
        let first: CGFloat
        let last: CGFloat
        /// One pixel of the screen the window is on, in points: how finely
        /// the layout placed what was measured.
        let devicePixel: CGFloat
    }

    /// How dark each pixel column of the window is at its darkest, from 0
    /// (white all the way down) to 1 (black somewhere in it), at
    /// `measuringScale`: what the glyphs, the fade, and the well leave.
    private struct Profile: Equatable {
        let columns: [CGFloat]
        /// Pixels per point in `columns`.
        let scale: CGFloat

        /// The column that starts at `x` points from the window's leading
        /// edge, one pixel wide.
        func at(_ x: CGFloat) -> CGFloat {
            let index = Int((x * scale).rounded(.down))
            return columns.indices.contains(index) ? columns[index] : 0
        }
    }

    /// Where an open field's caret is put before it is measured; nil leaves
    /// the label at rest.
    private enum Caret {
        /// The whole name selected and scrolled to its start, as an edit
        /// opens. In an inactive window the selection is a light gray, which
        /// the ink threshold does not count. No caret is drawn: one at the
        /// start blinks half a point before the first glyph.
        case start
        /// A bare caret at the start, scrolled fully left.
        case caretAtStart
        /// A bare caret at the end, scrolled fully right.
        case end
    }

    /// Underscores join into one unbroken line, so a name of them has ink
    /// in every column it crosses and a cut anywhere would show.
    private static let dashes = String(repeating: "_", count: 40)

    private func labelFrame(
        name: String,
        isEditing: Bool,
        offered: CGFloat? = nil,
        editingWidthLimit: CGFloat? = nil
    ) async throws -> CGRect {
        let recorder = FrameRecorder()
        let label = InlineRenameField(
            name: name,
            isEditing: .constant(isEditing),
            font: Self.font,
            foregroundColor: .black,
            onRename: { _ in },
            fillsWidth: false,
            editingWidthLimit: editingWidthLimit
        )
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { recorder.frame = $0 }
        let view = HStack(spacing: 0) {
            Color.white.frame(width: Self.gutter)
            if let offered {
                // As a cramped row offers it: no wider than this.
                label.frame(maxWidth: offered, alignment: .leading)
            } else {
                label
            }
            Spacer(minLength: 0)
        }
        let (window, host) = Self.hosted(view)
        defer { window.close() }
        if isEditing {
            await settle(host, timeout: Self.timeout) { Self.textField(in: host) != nil }
            #expect(Self.textField(in: host) != nil)
        }
        return try #require(await settledValue(in: host, timeout: Self.timeout) { recorder.frame })
    }

    private func inkColumns(
        name: String,
        isEditing: Bool,
        offered: CGFloat? = nil
    ) async -> Ink? {
        await inkColumns(name: name, caret: isEditing ? .end : nil, offered: offered)
    }

    private func inkColumns(
        name: String,
        caret: Caret?,
        offered: CGFloat? = nil,
        fillsWidth: Bool = false,
        font: Font = InlineRenameGeometryTests.font
    ) async -> Ink? {
        await measured(name: name, caret: caret, offered: offered, fillsWidth: fillsWidth, font: font) { host, window in
            Self.ink(in: host, devicePixel: 1 / window.backingScaleFactor)
        }
    }

    private func darkness(
        name: String,
        caret: Caret?,
        offered: CGFloat? = nil,
        fillsWidth: Bool = false
    ) async -> Profile? {
        await measured(name: name, caret: caret, offered: offered, fillsWidth: fillsWidth) { host, _ in
            Self.bitmap(of: host).map(Self.profile(of:))
        }
    }

    /// Where an open field draws its start and what bounds it, in points
    /// from the window's leading edge.
    private struct CaretExtents: Equatable {
        /// The insertion point before the first character, which is where
        /// the first glyph stands.
        let caretX: CGFloat
        /// The field editor's leading edge. Its content views clip to it.
        let editorMinX: CGFloat
        /// The leading edge of the clip view the field editor scrolls in.
        let clipMinX: CGFloat
    }

    /// The extents of the field editor's start, the label filling a row
    /// `rowWidth` wide, or at its own width when nil. The insertion point
    /// comes from the text input client, not the layout manager: asking an
    /// editor that lays out with TextKit 2 for its layout manager turns it
    /// to TextKit 1, which lays a scrolling text out differently.
    private func caretExtents(name: String, caret: Caret, rowWidth: CGFloat?, font: Font) async -> CaretExtents? {
        await measured(name: name, caret: caret, offered: rowWidth, fillsWidth: rowWidth != nil, font: font) { host, window in
            guard let editor = window.firstResponder as? NSTextView,
                  let clip = editor.superview as? NSClipView
            else { return nil }
            let onScreen = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
            let caret = host.convert(window.convertFromScreen(onScreen), from: nil)
            return CaretExtents(
                caretX: caret.minX,
                editorMinX: editor.convert(editor.bounds, to: host).minX,
                clipMinX: clip.convert(clip.bounds, to: host).minX
            )
        }
    }

    /// Hosts the label beside a white gutter, opens it with the caret where
    /// `caret` says (or leaves it at rest), and reads `value` once it settles.
    private func measured<Value: Equatable>(
        name: String,
        caret: Caret?,
        offered: CGFloat?,
        fillsWidth: Bool,
        font: Font = InlineRenameGeometryTests.font,
        _ value: (NSView, NSWindow) -> Value?
    ) async -> Value? {
        let view = HStack(spacing: 0) {
            Color.white.frame(width: Self.gutter)
            InlineRenameField(
                name: name,
                isEditing: .constant(caret != nil),
                font: font,
                foregroundColor: .black,
                onRename: { _ in },
                fillsWidth: fillsWidth
            )
            .frame(width: offered, alignment: .leading)
            Spacer(minLength: 0)
        }
        .background(Color.white)
        let (window, host) = Self.hosted(view)
        defer { window.close() }
        if let caret {
            // The field takes the keyboard on its own a few turns after it
            // mounts, selecting the name and scrolling to its start as it
            // does, and then aligns its editor. We wait those turns rather
            // than take the keyboard for it, so the caret is put and the glyphs
            // are read on a field that has opened, not on one still opening.
            await settle(host, timeout: Self.timeout) { Self.textField(in: host) != nil }
            await Self.waitForTheFieldToOpen(in: host)
            await settle(host, timeout: Self.timeout) { (window.firstResponder as? NSTextView)?.string == name }
            await Self.waitForTheFieldToOpen(in: host)
            guard let editor = window.firstResponder as? NSTextView, editor.string == name else { return nil }
            let length = (name as NSString).length
            switch caret {
            case .start:
                // As an edit opens: the whole name selected, which leaves no
                // caret to blink at its start, scrolled to that start.
                editor.setSelectedRange(NSRange(location: 0, length: length))
                editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
            case .caretAtStart:
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.scrollRangeToVisible(editor.selectedRange())
            case .end:
                // A bare caret at the end, out past the last glyph, leaves
                // only the glyphs to measure.
                editor.setSelectedRange(NSRange(location: length, length: 0))
                editor.scrollRangeToVisible(editor.selectedRange())
            }
        }
        return await settledValue(in: host, timeout: Self.timeout) { value(host, window) }
    }

    /// Runs the main queue past the turns an opening field waits for:
    /// `KeyboardHandoff`'s two, the update that focuses it, and the few
    /// `attachEditorAlignment` looks again for.
    private static func waitForTheFieldToOpen(in host: NSView) async {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            await KeyboardHandoff.responderSettled()
        }
    }

    /// A black block a label's height, `width` wide past the gutter, masked
    /// as an open inline field is, with black reaching well past it on
    /// either side so the outsets are filled.
    private func maskedBlock(width: CGFloat, overflow: InlineRenameOverflow) async -> Profile? {
        let view = HStack(spacing: 0) {
            Color.white.frame(width: Self.gutter)
            Color.clear
                .frame(width: width, height: 16)
                .overlay { Color.black.padding(.horizontal, -10) }
                .mask { InlineRenameMask(style: .inline, overflow: overflow) }
            Spacer(minLength: 0)
        }
        .background(Color.white)
        let (window, host) = Self.hosted(view)
        defer { window.close() }
        return await settledValue(in: host, timeout: Self.timeout) {
            Self.bitmap(of: host).map(Self.profile(of:))
        }
    }

    private static func hosted(_ view: some View) -> (NSWindow, NSView) {
        let size = CGSize(width: 320, height: 40)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Black on white in either system appearance.
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color.white))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        return (window, host)
    }

    private static func textField(in host: NSView) -> NSTextField? {
        descendants(of: host).lazy.compactMap { $0 as? NSTextField }.first
    }

    /// Dark pixels only: the text is black on white. Drawn into a bitmap
    /// of our own at `measuringScale`, rather than the one
    /// `bitmapImageRepForCachingDisplay` makes at the window's backing
    /// scale, so the measure is the same on every display.
    private static func ink(in host: NSView, devicePixel: CGFloat) -> Ink? {
        guard let rep = bitmap(of: host) else { return nil }
        let scale = measuringScale
        var first: Int?
        var last: Int?
        for x in 0..<rep.pixelsWide {
            let isInk = (0..<rep.pixelsHigh).contains { y in
                guard let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.5 else { return false }
                return color.redComponent < 0.6 && color.greenComponent < 0.6 && color.blueComponent < 0.6
            }
            if isInk {
                first = first ?? x
                last = x
            }
        }
        guard let first, let last else { return nil }
        return Ink(first: CGFloat(first) / scale, last: CGFloat(last) / scale, devicePixel: devicePixel)
    }

    private static func profile(of rep: NSBitmapImageRep) -> Profile {
        Profile(columns: (0..<rep.pixelsWide).map { x in
            (0..<rep.pixelsHigh).reduce(CGFloat(0)) { darkest, y in
                guard let color = rep.colorAt(x: x, y: y) else { return darkest }
                let lightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                return max(darkest, 1 - lightness)
            }
        }, scale: measuringScale)
    }

    /// The host drawn into a bitmap of our own at `measuringScale`.
    private static func bitmap(of host: NSView) -> NSBitmapImageRep? {
        host.layoutSubtreeIfNeeded()
        let size = host.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * measuringScale),
            pixelsHigh: Int(size.height * measuringScale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
}
