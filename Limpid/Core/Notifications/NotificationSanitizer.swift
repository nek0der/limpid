// NotificationSanitizer.swift
// Limpid — strip dangerous / decorative Unicode out of strings before
// they reach `UNUserNotificationCenter` or any other UI surface.
//
// Ported from Calyx (`Features/Notifications/NotificationSanitizer.swift`,
// MIT licensed) and adjusted only for naming.

import Foundation

enum NotificationSanitizer {

    /// Run a defense-in-depth pass on terminal-supplied text:
    /// - Bidi override / isolation marks → removed.
    /// - C0 / C1 control chars → removed (tab + newline preserved).
    /// - Zero-width spaces / joiners / marks → removed.
    /// - Consecutive newlines collapsed to a single `\n`, trim ends.
    /// - Unicode NFC normalization.
    /// - 256 grapheme cluster cap so a runaway escape sequence can't
    ///   spam a full-screen notification body.
    static func sanitize(_ text: String) -> String {
        var result = text

        // Strip bidi overrides (U+202A-202E, U+2066-2069), C0 / C1
        // control chars (except \t and \n), and zero-width / joiner
        // marks (U+200B-200F, U+FEFF) in one pass. We deliberately
        // avoid Swift regex character-class ranges with `\u{}` escapes
        // (`/[\u{200B}-\u{200F}]/`) because Regex literals drop the
        // interior code points of such ranges in current toolchains —
        // ZWNJ (U+200C) and ZWJ (U+200D) slip through. Filtering scalar
        // by scalar is both cheaper and unambiguous.
        result = result.unicodeScalars.filter { scalar in
            let v = scalar.value
            // Allow tab and newline.
            if v == 0x09 || v == 0x0A { return true }
            // Strip C0 control chars (0x00-0x1F minus tab/newline).
            if v <= 0x1F { return false }
            // Strip DEL.
            if v == 0x7F { return false }
            // Strip C1 control chars (0x80-0x9F).
            if v >= 0x80, v <= 0x9F { return false }
            // Strip invisible-spacing / direction marks that are common
            // attack vectors: ZWSP (200B), LRM (200E), RLM (200F).
            // Deliberately *preserve* ZWNJ (200C) and ZWJ (200D) — the
            // former matters for Persian/Arabic ligature suppression,
            // the latter is load-bearing for modern emoji sequences
            // (family / skin-tone / profession). Stripping them would
            // garble user-visible text without meaningful safety win.
            if v == 0x200B { return false }
            if v == 0x200E || v == 0x200F { return false }
            // Strip BOM / ZWNBSP.
            if v == 0xFEFF { return false }
            // Strip bidi overrides + isolation marks.
            if v >= 0x202A, v <= 0x202E { return false }
            if v >= 0x2066, v <= 0x2069 { return false }
            return true
        }.map { String($0) }.joined()

        // Normalize newlines: collapse runs, strip leading / trailing.
        result = result.replacing(/\n{2,}/, with: "\n")
        result = result.trimmingCharacters(in: .newlines)

        // Unicode NFC normalization.
        result = result.precomposedStringWithCanonicalMapping

        // Truncate to 256 grapheme clusters.
        if result.count > 256 {
            result = String(result.prefix(256))
        }

        return result
    }
}
