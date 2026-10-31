// ContainerSymbol.swift
// Weir — the symbol each kind of container is drawn with.

/// SF Symbol per container kind, read by every surface that names a
/// container, the command palette catalog among them, so each draws the same
/// glyph. A name rather than an image, as the catalog's other icons are. The
/// set divides containers by what they own: a repository, a branch.
enum ContainerSymbol {
    static let project = "book.closed"
    static let worktree = "arrow.triangle.branch"
}
