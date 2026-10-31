// CatalogFixture.swift
// Weir — reads the string units out of a parsed `Localizable.xcstrings` entry.

/// This is the catalog walk the wording suites share, so a new variation
/// shape is taught to every check at once rather than to whichever suite met
/// it first.
enum CatalogFixture {
    /// Returns every string unit under a localization: plural and device
    /// variations and substitutions hold theirs further down.
    static func values(in node: Any?) -> [String] {
        if let list = node as? [Any] {
            return list.flatMap { values(in: $0) }
        }
        guard let dictionary = node as? [String: Any] else { return [] }
        if let unit = dictionary["stringUnit"] as? [String: Any], let value = unit["value"] as? String {
            return [value]
        }
        return dictionary.values.flatMap { values(in: $0) }
    }
}
