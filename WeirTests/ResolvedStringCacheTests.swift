// ResolvedStringCacheTests.swift
// Weir — the remembered words of a localized resource: kept apart by language and value, and only the latest few values of one key.

import Foundation
import Testing
@testable import Weir

struct ResolvedStringCacheTests {
    /// The remembered words are the resource's in its language, its
    /// interpolated values included: another language or another value is
    /// another entry.
    @Test func aRememberedResource_isKeptApartByLanguageAndValue() {
        let ja = Locale(identifier: "ja")
        let en = Locale(identifier: "en")
        #expect(LocalizedStringResource("Unread").resolved(in: ja) == "未読")
        #expect(LocalizedStringResource("Unread").resolved(in: en) == "Unread")
        #expect(LocalizedStringResource("Unread").resolved(in: ja) == "未読")
        let one = 1
        let two = 2
        #expect(LocalizedStringResource("\(one) unread").resolved(in: en) != LocalizedStringResource("\(two) unread").resolved(in: en))
    }

    /// One key given thousands of values keeps only its latest few, so a
    /// lookup for it stays as quick as for a key with one value, and what
    /// another key remembers is untouched by them.
    @Test func manyValuesOfOneKey_keepOnlyTheLatest_andTheLookupStaysShort() {
        let cache = ResolvedStringCache()
        let en = Locale(identifier: "en")
        func unread(_ count: Int) -> LocalizedStringResource {
            var resource = LocalizedStringResource("\(count) unread")
            resource.locale = en
            return resource
        }
        var other = LocalizedStringResource("Unread")
        other.locale = en
        #expect(cache.string(for: other) == "Unread")
        for count in 0..<3000 {
            _ = cache.string(for: unread(count))
        }
        #expect(cache.count(ofKeyOf: unread(0)) == ResolvedStringCache.perKeyLimit)
        #expect(cache.count(ofKeyOf: other) == 1)
        // The latest value is found where it was put, the first long gone
        // is looked up again and put first.
        #expect(cache.string(for: unread(2999)).hasSuffix("999 unread"))
        #expect(cache.string(for: unread(0)) == "0 unread")
        #expect(cache.count(ofKeyOf: unread(0)) == ResolvedStringCache.perKeyLimit)
    }
}
