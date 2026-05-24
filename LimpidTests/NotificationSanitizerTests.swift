// NotificationSanitizerTests.swift
// Verifies the defense-in-depth filter that runs on every
// terminal-supplied notification body before it reaches AppKit.
// Regression guard for the ported Calyx implementation.

import Testing
@testable import Limpid

@Suite("NotificationSanitizer")
struct NotificationSanitizerTests {

    @Test("trims surrounding whitespace and newlines")
    func sanitize_trimsLeadingAndTrailingNewlines() {
        #expect(NotificationSanitizer.sanitize("\n\nhello\n\n") == "hello")
    }

    @Test("collapses consecutive newlines to a single newline")
    func sanitize_collapsesConsecutiveNewlines() {
        #expect(NotificationSanitizer.sanitize("a\n\n\n\nb") == "a\nb")
    }

    @Test(
        "strips control characters but keeps tab and newline",
        arguments: [
            ("a\u{0001}b", "ab"), // C0 (SOH)
            ("a\u{001F}b", "ab"), // C0 (US)
            ("a\u{007F}b", "ab"), // DEL
            ("a\u{0085}b", "ab"), // C1 (NEL)
            ("a\tb", "a\tb"), // tab preserved
            ("line1\nline2", "line1\nline2"),
        ]
    )
    func sanitize_controlCharacters(input: String, expected: String) {
        #expect(NotificationSanitizer.sanitize(input) == expected)
    }

    @Test(
        "strips invisible-spacing and bidi-override characters",
        arguments: [
            ("a\u{200B}b", "ab"), // ZWSP
            ("a\u{200E}b", "ab"), // LRM
            ("a\u{200F}b", "ab"), // RLM
            ("a\u{FEFF}b", "ab"), // BOM
            ("a\u{202A}b", "ab"), // LRE
            ("a\u{202E}b", "ab"), // RLO (bidi override)
            ("a\u{2066}b\u{2069}", "ab"), // LRI / PDI
        ]
    )
    func sanitize_invisibleSpacingAndBidi(input: String, expected: String) {
        #expect(NotificationSanitizer.sanitize(input) == expected)
    }

    /// ZWNJ (U+200C) and ZWJ (U+200D) are intentionally preserved so
    /// emoji sequences and Persian / Arabic ligature suppression aren't
    /// mangled in notification text.
    @Test("preserves ZWJ / ZWNJ so emoji sequences and ligatures survive")
    func sanitize_preservesZWNJandZWJ() {
        #expect(NotificationSanitizer.sanitize("a\u{200C}b") == "a\u{200C}b")
        #expect(NotificationSanitizer.sanitize("a\u{200D}b") == "a\u{200D}b")
    }

    @Test("caps result at 256 grapheme clusters")
    func sanitize_overSizedInput_truncatesTo256Graphemes() {
        let long = String(repeating: "a", count: 1000)
        let sanitized = NotificationSanitizer.sanitize(long)
        #expect(sanitized.count == 256)
    }

    @Test("emoji counted as one grapheme stays under the cap")
    func sanitize_emojiHeavyInput_truncatesByGraphemeNotByteCount() {
        // 100 family emoji ≈ each is one grapheme but many bytes.
        let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 100)
        let sanitized = NotificationSanitizer.sanitize(emoji)
        #expect(sanitized.count == 100)
    }

    @Test("NFC normalizes decomposed forms")
    func sanitize_decomposedUnicode_isNormalizedToNFC() {
        // 'é' as decomposed (e + COMBINING ACUTE ACCENT, 2 scalars)
        let decomposed = "e\u{0301}"
        let sanitized = NotificationSanitizer.sanitize(decomposed)
        // NFC composed form is a single scalar U+00E9.
        #expect(sanitized == "\u{00E9}")
    }

    @Test("empty input stays empty")
    func sanitize_emptyInput_returnsEmpty() {
        #expect(NotificationSanitizer.sanitize("") == "")
    }
}
