// ReviewRowPainter.swift
// Limpid — the drawing shared by the review rows and the frozen gutter.

import AppKit
import SwiftUI

/// Colors shared by the scrolling rows and the frozen gutter, which draws the
/// same backgrounds so the two halves of a row cannot disagree.
/// `@MainActor` for the attribute cache below: these are drawing helpers, and
/// `draw(_:)` only ever runs on the main thread.
@MainActor
enum ReviewRowPainter {
    /// The accent the reader picked, as AppKit sees it.
    ///
    /// These rows draw outside SwiftUI and cannot read `\.limpidAccent`
    /// themselves, and `NSColor.controlAccentColor` is the system's accent
    /// rather than the app's — half of review followed the picker and half
    /// followed macOS. Kept here because the painter is what reads it; the
    /// table hands it over on every update.
    private(set) static var accent = NSColor(LimpidColor.defaultAccent)

    /// The same value as SwiftUI holds it, which is what makes the comparison
    /// below reliable: two `NSColor`s built from one `Color` are not equal,
    /// while the `Color`s this app can supply — the named system colors and
    /// `Color.accentColor` — compare equal across separate reads. That was
    /// measured rather than assumed, because a comparison that reported a
    /// change on every update would reload every row of the diff.
    private static var accentSource = LimpidColor.defaultAccent

    /// Adopt the accent the reader picked. Each table decides for itself
    /// whether that is a change it has yet to draw, so this only records.
    static func setAccent(_ color: Color) {
        guard color != accentSource else { return }
        accentSource = color
        accent = NSColor(color)
    }

    /// How many cells a tab is worth while estimating how wide a line is.
    /// AppKit's default tab stops sit every 28pt, which is close to four cells
    /// of the code font. Nothing is drawn from this — it only ranks lines — so
    /// the fraction of a cell it is off by does not matter.
    private static let tabStop = 4

    /// Roughly how many cells a line takes, used only to rank lines against
    /// each other before the few widest are measured properly.
    ///
    /// Not a width. Being off by a cell on an ambiguous-width character costs
    /// nothing: it only has to put the real widest line among the candidates.
    /// Counting characters instead left it out of them — one line of Japanese
    /// outdraws a longer line of ASCII.
    static func cells(in text: String) -> Int {
        var cells = 0
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                cells += tabStop - (cells % tabStop)
            } else {
                cells += isWide(scalar) ? 2 : 1
            }
        }
        return cells
    }

    /// The ranges that are two cells wide in a monospaced font, coarse enough
    /// to stay one comparison per scalar.
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF: true
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF: true
        case 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F: true
        case 0xFF00...0xFF60, 0xFFE0...0xFFE6: true
        case 0x1F300...0x1F9FF, 0x20000...0x3FFFD: true
        default: false
        }
    }

    static func background(for kind: ReviewLine.Kind, isSelected: Bool) -> NSColor {
        let base: NSColor = switch kind {
        case .added: NSColor.systemGreen.withAlphaComponent(0.13)
        case .removed: NSColor.systemRed.withAlphaComponent(0.12)
        default: .clear
        }
        guard isSelected else { return base }
        // One color for a selected line, whatever kind it is. Blending the
        // accent into the change tint gave three different, and all faint,
        // selections; the band at the left still says added or removed.
        return accent.withAlphaComponent(0.34)
    }

    static func band(for kind: ReviewLine.Kind) -> NSColor {
        switch kind {
        case .added: NSColor.systemGreen
        case .removed: NSColor.systemRed
        default: .clear
        }
    }

    /// The opaque strip the line numbers sit on.
    ///
    /// Two coats, because the surface color is translucent by design — it sits
    /// over the window's vibrancy — and one coat let what is behind the diff
    /// show through the numbers. In the unified layout that was the code
    /// scrolling sideways underneath them; in the split layout it made the
    /// number column read as part of the code rather than as its margin.
    static func fillNumberStrip(_ rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        rect.fill()
        NSColor(LimpidColor.terminalColumnBackground).setFill()
        rect.fill()
    }

    /// The narrow column between the change band and the numbers. It carries
    /// one mark per line and nothing else, so the add-comment target and the
    /// has-feedback dot never collide with a line number.
    ///
    /// `row` is the strip being drawn: the whole gutter in the unified layout,
    /// one column's half of the row in the split one.
    static func markerRect(in row: NSRect) -> NSRect {
        let size: CGFloat = 13
        return NSRect(
            x: row.minX + ReviewRowMetrics.bandWidth + (ReviewRowMetrics.gutterWidth - size) / 2,
            y: row.midY - size / 2,
            width: size,
            height: size
        )
    }

    static func drawAddMarker(in rect: NSRect) {
        accent.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()
        let bar: CGFloat = 6
        let thickness: CGFloat = 1.5
        NSColor.white.setFill()
        NSRect(
            x: rect.midX - bar / 2, y: rect.midY - thickness / 2,
            width: bar, height: thickness
        ).fill()
        NSRect(
            x: rect.midX - thickness / 2, y: rect.midY - bar / 2,
            width: thickness, height: bar
        ).fill()
    }

    /// A dot, not a count. The number read as a line number in a column of
    /// line numbers, and how many comments a line carries is answered by the
    /// cards sitting right under it.
    static func drawCommentDot(in marker: NSRect) {
        let size: CGFloat = 5
        let rect = NSRect(
            x: marker.midX - size / 2, y: marker.midY - size / 2,
            width: size, height: size
        )
        accent.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// The hatch that stands in for a line the other column does not have.
    ///
    /// Drawn as strokes in a dynamic color rather than a pattern image:
    /// `NSColor(patternImage:)` phases against the window rather than the row,
    /// and a pattern does not follow the appearance, so it would have to be
    /// rebuilt on every light/dark switch.
    ///
    /// `phase` is the row's offset in the document, so the hatch of one
    /// placeholder continues into the next instead of restarting every row.
    static func drawPlaceholder(in rect: NSRect, phase: CGFloat) {
        guard rect.width > 0, rect.height > 0 else { return }
        NSColor.separatorColor.withAlphaComponent(0.12).setFill()
        rect.fill()
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: rect).setClip()
        // Quieter than the code opposite, which is what a placeholder marks the
        // absence of — but not so quiet that the column reads as a pane that
        // failed to draw. At a third of this it was only legible zoomed in.
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        let spacing: CGFloat = 7
        let path = NSBezierPath()
        path.lineWidth = 1
        // The lines run at 45 degrees, so a line that starts `height` to the
        // left of the rect is the first one that can still cross it.
        let offset = phase.truncatingRemainder(dividingBy: spacing)
        var x = rect.minX - rect.height - offset
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        path.stroke()
    }

    /// One column's code, drawn `offset` points to the left of its cell and
    /// clipped to it. Both columns take the same offset, so a long line is read
    /// by scrolling the code while the numbers, the change bands and the
    /// divider stay where they are.
    ///
    /// The ellipsis is only for the resting position: once the reader has
    /// scrolled, the end of the line is something they are moving toward, not a
    /// thing to mark.
    static func drawCode(
        _ text: String,
        in cell: NSRect,
        offset: CGFloat,
        font: NSFont,
        color: NSColor,
        language: ReviewSyntax.Language? = nil,
        match: String = ""
    ) {
        guard !text.isEmpty, cell.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: cell).setClip()
        let attributes = attributes(font: font, color: color, alignment: .left, truncates: offset <= 0)
        let height = (text as NSString).size(withAttributes: attributes).height
        let box = NSRect(
            x: cell.minX - offset,
            y: cell.minY + (cell.height - height) / 2,
            width: cell.width + offset,
            height: height
        )
        if let styled = styled(text, language: language, match: match, attributes: attributes) {
            styled.draw(in: box)
        } else {
            (text as NSString).draw(in: box, withAttributes: attributes)
        }
    }

    /// The line as it is drawn: colored by the language, then marked with the
    /// search query. `nil` when neither applies and the caller should draw the
    /// plain string, which is most lines of most diffs.
    ///
    /// The search goes on last on purpose. It is the reader's own question,
    /// and it has to win over syntax that is only there to be skimmed.
    static func styled(
        _ text: String,
        language: ReviewSyntax.Language?,
        match: String,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString? {
        let tokens = language.map { ReviewSyntax.tokens(in: text, language: $0) } ?? []
        let found = ReviewSearch.ranges(in: text, query: match)
        guard !tokens.isEmpty || !found.isEmpty else { return nil }
        let result = NSMutableAttributedString(string: text, attributes: attributes)
        for token in tokens {
            result.addAttribute(.foregroundColor, value: color(for: token.kind), range: NSRange(token.range, in: text))
        }
        // The system's find color, with black text over it: that pairing is
        // what every find bar on the platform draws, and both the label color
        // and the syntax colors underneath are light in the dark appearance,
        // which would be unreadable on it.
        for range in found {
            let span = NSRange(range, in: text)
            result.addAttribute(.backgroundColor, value: NSColor.findHighlightColor, range: span)
            result.addAttribute(.foregroundColor, value: NSColor.black, range: span)
        }
        return result
    }

    /// System colors, which follow the appearance on their own. Comments are
    /// gray rather than the green an editor would use: a comment on an added
    /// line would otherwise be green text on a green ground.
    private static func color(for kind: ReviewSyntax.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .string: .systemRed
        case .number: .systemOrange
        case .comment: .secondaryLabelColor
        }
    }

    /// Attribute dictionaries and paragraph styles are rebuilt for every line
    /// number otherwise, on every redraw.
    private static var attributeCache: [String: [NSAttributedString.Key: Any]] = [:]

    static func attributes(
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment,
        truncates: Bool
    ) -> [NSAttributedString.Key: Any] {
        let key = "\(font.fontName)-\(font.pointSize)-\(color.hash)-\(alignment.rawValue)-\(truncates)"
        if let cached = attributeCache[key] {
            return cached
        }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        // Never the default `.byWordWrapping`: a cell is one row tall, so a
        // line that wrapped lost everything past its first visual line. That
        // showed as the end of the line going missing the moment the reader
        // scrolled a column sideways.
        style.lineBreakMode = truncates ? .byTruncatingTail : .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: style
        ]
        if attributeCache.count >= 128 {
            attributeCache.removeAll(keepingCapacity: true)
        }
        attributeCache[key] = attributes
        return attributes
    }

    /// A line number or another short label, centered in the row it belongs to:
    /// `NSString.draw` puts text at the top of the rect it is given.
    static func draw(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        guard !text.isEmpty else { return }
        let attributes = attributes(font: font, color: color, alignment: alignment, truncates: false)
        let height = (text as NSString).size(withAttributes: attributes).height
        (text as NSString).draw(
            in: NSRect(
                x: rect.minX, y: rect.minY + (rect.height - height) / 2,
                width: rect.width, height: height
            ),
            withAttributes: attributes
        )
    }
}
