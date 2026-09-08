// ReviewFileTree.swift
// Limpid — how the changed-file list is grouped and described.

import Foundation

/// Grouping and naming for the changed-file list. Model work, kept out of the
/// view that draws it: a view type cannot be reached from a unit test without
/// bringing the whole app up with it.
enum ReviewFileTree {
    /// Files grouped by the directory that holds them, in path order. Files at
    /// the repository root group under an empty path.
    static func directories(_ files: [ReviewFile]) -> [(path: String, files: [ReviewFile])] {
        var groups: [String: [ReviewFile]] = [:]
        for file in files {
            groups[parent(file.path) ?? "", default: []].append(file)
        }
        return groups
            .map { (path: $0.key, files: $0.value.sorted { ($0.path, $0.id) < ($1.path, $1.id) }) }
            .sorted { $0.path < $1.path }
    }

    /// The files a reader who is hiding what they have read should still see.
    ///
    /// The open one stays whatever its mark says: a list that denied the file
    /// on screen was there would be answering a different question from the
    /// diff beside it. The rail draws this set and `n` / `p` walk it, and they
    /// were each spelling the rule out for themselves.
    static func listed(
        _ files: [ReviewFile],
        hidingViewed: Bool,
        viewed: Set<String>,
        open: String?
    ) -> [ReviewFile] {
        guard hidingViewed else { return files }
        return files.filter { !viewed.contains($0.id) || $0.id == open }
    }

    /// The files in the order the rail draws them.
    ///
    /// `n` and `p` walk this list too. They used to step through the store's
    /// own order — layer then path — which is what the flat list shows and not
    /// what the tree does, so in tree mode the keys jumped around the rail
    /// instead of down it.
    static func ordered(_ files: [ReviewFile], isTree: Bool) -> [ReviewFile] {
        guard isTree else {
            // Layer in declaration order, then path: `ReviewLayer.allCases` is
            // the rail's section order, and `rawValue` is not it.
            return files.sorted { first, second in
                let left = ReviewLayer.allCases.firstIndex(of: first.layer) ?? 0
                let right = ReviewLayer.allCases.firstIndex(of: second.layer) ?? 0
                return left == right ? first.path < second.path : left < right
            }
        }
        return directories(files).flatMap(\.files)
    }

    static func name(_ path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }

    static func parent(_ path: String) -> String? {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// What a row shows besides its name, spoken rather than drawn.
    static func summary(layer: ReviewLayer, stat: ReviewFileStat?, comments: Int) -> String {
        var parts = [layer.title]
        if let stat {
            parts.append(stat.isBinary ? String(localized: "binary") : "+\(stat.added) −\(stat.removed)")
        }
        if comments > 0 {
            parts.append(String(localized: "\(comments) comments"))
        }
        return parts.joined(separator: ", ")
    }
}
