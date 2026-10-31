// LocalizedStringResource+Resolved.swift
// Weir — the one place localized text is resolved to a `String`.
//
// `String(localized:)` answers in the language the process launched with,
// however late it is called, so a `String` resolved that way stays in the
// old language after the user switches Display Language in Settings. Models
// carry `LocalizedStringResource`, views hand it to SwiftUI, and text that
// has to be a `String` comes through here with the environment or app
// locale. The `launch_language_lookup` lint rule keeps the raw lookup out of
// every other file.

import Foundation
import Synchronization

extension LocalizedStringResource {
    /// This string in `locale`'s language. SwiftUI's `\.locale` carries the
    /// language chosen in Settings from the moment it is picked, while a
    /// plain lookup answers in the language the process launched with; text
    /// that has to be a `String` (an AppKit menu, an accessibility join, a
    /// search index) resolves through here to switch with the rest of the
    /// window.
    ///
    /// Remembered (`ResolvedStringCache`): Foundation reads the language's
    /// table again for every lookup in a language it was not launched in,
    /// about 0.6 ms each, where a plain lookup takes under a microsecond.
    /// Every row's words, tooltip, and spoken label come through here, so a
    /// list scrolling new rows in spent whole frames on it.
    func resolved(in locale: Locale) -> String {
        var resource = self
        resource.locale = locale
        return ResolvedStringCache.shared.string(for: resource)
    }
}

extension Locale {
    /// English, for search aliases that match the English name whatever
    /// language the app shows.
    static let english = Locale(identifier: "en")
}

/// What each resource has resolved to. The same resource always resolves
/// to the same words, since the bundle does not change while the app runs.
///
/// Two levels: a list per key (its key, table, language, and bundle), of
/// which there are as many as the catalog has strings, and in each list
/// the values interpolated into that key, most recently used first. A key
/// whose values run without end (counts, names, paths) keeps only its
/// latest `perKeyLimit`, so neither the memory nor a lookup grows with
/// them, and one key's values never push another key's words out.
final class ResolvedStringCache: Sendable {
    static let shared = ResolvedStringCache()
    static let perKeyLimit = 24

    /// What tells one key's list from another's. Foundation's resource is
    /// Equatable only, so the parts are taken out here.
    struct ListKey: Hashable {
        let key: String
        let table: String?
        let locale: String
        let bundle: String

        init(_ resource: LocalizedStringResource) {
            key = resource.key
            table = resource.table
            locale = resource.locale.identifier
            bundle = switch resource.bundle {
            case .main: "main"
            case let .forClass(type): NSStringFromClass(type)
            case let .atURL(url): url.absoluteString
            // A kind of bundle a later system adds: told apart by its
            // description, which names it.
            @unknown default: String(describing: resource.bundle)
            }
        }
    }

    /// One resolved resource, compared whole, its interpolated values
    /// included.
    private struct Entry {
        let resource: LocalizedStringResource
        let string: String
    }

    private let lists = Mutex<[ListKey: [Entry]]>([:])

    /// How many resources of `resource`'s key are remembered, for the
    /// tests.
    func count(ofKeyOf resource: LocalizedStringResource) -> Int {
        lists.withLock { $0[ListKey(resource)]?.count ?? 0 }
    }

    func string(for resource: LocalizedStringResource) -> String {
        let listKey = ListKey(resource)
        let known: String? = lists.withLock { lists in
            guard var entries = lists[listKey],
                  let index = entries.firstIndex(where: { $0.resource == resource })
            else { return nil }
            let entry = entries[index]
            if index > 0 {
                entries.remove(at: index)
                entries.insert(entry, at: 0)
                lists[listKey] = entries
            }
            return entry.string
        }
        if let known {
            return known
        }
        // Looked up outside the lock: two threads asking at once each look
        // it up, and the second finds the first's words already there.
        let resolved = String(localized: resource)
        lists.withLock { lists in
            var entries = lists[listKey] ?? []
            guard !entries.contains(where: { $0.resource == resource }) else { return }
            entries.insert(Entry(resource: resource, string: resolved), at: 0)
            if entries.count > Self.perKeyLimit {
                entries.removeLast(entries.count - Self.perKeyLimit)
            }
            lists[listKey] = entries
        }
        return resolved
    }
}
