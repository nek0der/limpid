// ClipboardWriteTextTests.swift
// Weir — what text a terminal's clipboard write (OSC 52) puts on the pasteboard.

import Foundation
import GhosttyKit
import Testing
@testable import Weir

struct ClipboardWriteTextTests {
    /// Calls `body` with `entries` laid out as libghostty hands them over:
    /// each with its mime type, its bytes, and their length. A NUL follows
    /// the bytes, outside the length, so a reader that wrongly stops at a
    /// NUL fails the expectation rather than reading past the buffer.
    private func withContents<T>(
        _ entries: [(mime: String, bytes: [UInt8])],
        _ body: (UnsafePointer<ghostty_clipboard_content_s>, Int) -> T
    ) -> T {
        let mimes = entries.map { strdup($0.mime) }
        let buffers = entries.map { entry -> UnsafeMutablePointer<CChar> in
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: entry.bytes.count + 1)
            for (index, byte) in entry.bytes.enumerated() {
                buffer[index] = CChar(bitPattern: byte)
            }
            buffer[entry.bytes.count] = 0
            return buffer
        }
        defer {
            mimes.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }
        let contents = entries.indices.map { index in
            ghostty_clipboard_content_s(
                mime: UnsafePointer(mimes[index]),
                data: UnsafePointer(buffers[index]),
                len: entries[index].bytes.count
            )
        }
        return contents.withUnsafeBufferPointer { pointer in
            body(pointer.baseAddress!, entries.count)
        }
    }

    /// The bytes count by their length: a NUL inside them is copied, not
    /// taken as their end.
    @Test func aWrite_takesItsBytesByLength() {
        let text = withContents([("text/plain", Array("a\u{0}b".utf8))]) {
            GhosttyFFI.clipboardWriteText($0, count: $1)
        }
        #expect(text == "a\u{0}b")
    }

    @Test func aWrite_prefersPlainText() {
        let text = withContents([("text/html", Array("<b>x</b>".utf8)), ("text/plain", Array("x".utf8))]) {
            GhosttyFFI.clipboardWriteText($0, count: $1)
        }
        #expect(text == "x")
    }

    @Test func aWriteWithoutPlainText_takesItsFirst() {
        let text = withContents([("text/html", Array("<b>x</b>".utf8))]) {
            GhosttyFFI.clipboardWriteText($0, count: $1)
        }
        #expect(text == "<b>x</b>")
    }
}
