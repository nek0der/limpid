// SplitTree.swift
// Limpid — immutable binary tree of pane leaves with ratio-based layout.
//
// Adapted from Calyx/Models/SplitTree.swift (MIT). The algorithm and data
// shape are a direct port; the type lives in our Models namespace so the
// rest of the app can iterate on focus / persistence logic without leaning
// on Calyx-specific surrounding types.

import Foundation

// MARK: - Direction types

enum SplitDirection: String, Codable, Equatable {
    /// Divider runs vertically, panes side-by-side (first | second).
    case horizontal
    /// Divider runs horizontally, panes stacked (first / second).
    case vertical
}

enum SpatialDirection {
    case left, right, up, down
}

enum FocusDirection {
    case previous
    case next
    case spatial(SpatialDirection)
}

// MARK: - SplitNode

indirect enum SplitNode: Codable, Equatable {
    case leaf(id: UUID)
    case split(SplitData)

    var leafID: UUID? {
        if case let .leaf(id) = self { return id }
        return nil
    }
}

// MARK: - SplitData

struct SplitData: Codable, Equatable {
    let direction: SplitDirection
    let ratio: Double
    let first: SplitNode
    let second: SplitNode

    init(direction: SplitDirection, ratio: Double, first: SplitNode, second: SplitNode) {
        self.direction = direction
        self.ratio = Self.clampRatio(ratio)
        self.first = first
        self.second = second
    }

    /// Clamp the split ratio to a safe range so dividers can't be dragged
    /// past either pane's minimum visible width / height.
    static func clampRatio(_ ratio: Double) -> Double {
        min(max(ratio, 0.1), 0.9)
    }
}

// MARK: - SplitTree

struct SplitTree: Codable, Equatable {
    var root: SplitNode?
    var focusedLeafID: UUID?

    init(root: SplitNode? = nil, focusedLeafID: UUID? = nil) {
        self.root = root
        self.focusedLeafID = focusedLeafID
    }

    init(leafID: UUID) {
        self.root = .leaf(id: leafID)
        self.focusedLeafID = leafID
    }

    var isEmpty: Bool {
        root == nil
    }

    var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    // MARK: - Insert

    /// Insert a new leaf next to an existing one, splitting it in the
    /// given direction. Returns the resulting tree and the new leaf's id.
    func insert(
        at leafID: UUID,
        direction: SplitDirection,
        newID: UUID = UUID()
    ) -> (tree: SplitTree, newLeafID: UUID) {
        guard let root else {
            // Empty tree → just plant the new leaf as root.
            return (
                SplitTree(root: .leaf(id: newID), focusedLeafID: newID),
                newID
            )
        }
        let newRoot = Self.replaceLeaf(in: root, id: leafID) { existing in
            .split(SplitData(
                direction: direction,
                ratio: 0.5,
                first: existing,
                second: .leaf(id: newID)
            ))
        }
        return (
            SplitTree(root: newRoot, focusedLeafID: newID),
            newID
        )
    }

    // MARK: - Remove

    /// Remove the leaf with the given id. The sibling collapses up into
    /// the removed leaf's slot. Returns the new tree and the leaf that
    /// should receive focus (or nil if the tree is now empty).
    func remove(_ leafID: UUID) -> (tree: SplitTree, focusTarget: UUID?) {
        guard let root else { return (self, nil) }
        let (newRoot, focusTarget) = Self.removeLeaf(in: root, id: leafID)
        if let newRoot {
            return (
                SplitTree(root: newRoot, focusedLeafID: focusTarget),
                focusTarget
            )
        }
        return (SplitTree(), nil)
    }

    // MARK: - Resize

    /// Move the divider that wraps the given leaf along its parent split.
    /// `amount` is in points; converted to a ratio delta using `bounds`.
    func resize(
        node leafID: UUID,
        by amount: Double,
        direction: SplitDirection,
        bounds: CGSize,
        minSize: CGFloat
    ) -> SplitTree {
        guard let root else { return self }
        let newRoot = Self.resizeSplit(
            in: root,
            leafID: leafID,
            direction: direction,
            amount: amount,
            bounds: bounds,
            minSize: minSize
        )
        return SplitTree(root: newRoot, focusedLeafID: focusedLeafID)
    }

    /// Reset every split in the tree to a 50/50 ratio.
    func equalize() -> SplitTree {
        guard let root else { return self }
        return SplitTree(
            root: Self.equalizeNode(root),
            focusedLeafID: focusedLeafID
        )
    }

    // MARK: - Inspection

    func allLeafIDs() -> [UUID] {
        guard let root else { return [] }
        var ids: [UUID] = []
        Self.collectLeafIDs(in: root, into: &ids)
        return ids
    }

    /// Remap every leaf id through the given mapping. Used when restoring
    /// a tree whose ids need to be renumbered (e.g. cloning a session).
    func remapLeafIDs(_ mapping: [UUID: UUID]) -> SplitTree {
        guard let root else { return self }
        let newRoot = Self.remapNode(root, mapping: mapping)
        let newFocus = focusedLeafID.flatMap { mapping[$0] ?? $0 }
        return SplitTree(root: newRoot, focusedLeafID: newFocus)
    }

    // MARK: - Private helpers

    private static func replaceLeaf(
        in node: SplitNode,
        id targetID: UUID,
        with replacement: (SplitNode) -> SplitNode
    ) -> SplitNode {
        switch node {
        case let .leaf(id) where id == targetID:
            replacement(node)
        case .leaf:
            node
        case let .split(data):
            .split(SplitData(
                direction: data.direction,
                ratio: data.ratio,
                first: replaceLeaf(in: data.first, id: targetID, with: replacement),
                second: replaceLeaf(in: data.second, id: targetID, with: replacement)
            ))
        }
    }

    private static func removeLeaf(
        in node: SplitNode,
        id targetID: UUID
    ) -> (SplitNode?, UUID?) {
        switch node {
        case let .leaf(id) where id == targetID:
            return (nil, nil)
        case .leaf:
            return (node, nil)
        case let .split(data):
            // Recurse first, see what each side returns.
            let (newFirst, firstFocus) = removeLeaf(in: data.first, id: targetID)
            let (newSecond, secondFocus) = removeLeaf(in: data.second, id: targetID)
            switch (newFirst, newSecond) {
            case let (nil, .some(remaining)):
                return (remaining, firstLeafID(of: remaining))
            case let (.some(remaining), nil):
                return (remaining, firstLeafID(of: remaining))
            case let (.some(f), .some(s)):
                return (
                    .split(SplitData(
                        direction: data.direction,
                        ratio: data.ratio,
                        first: f,
                        second: s
                    )),
                    firstFocus ?? secondFocus
                )
            case (nil, nil):
                return (nil, nil)
            }
        }
    }

    static func firstLeafID(of node: SplitNode) -> UUID? {
        switch node {
        case let .leaf(id): id
        case let .split(data):
            firstLeafID(of: data.first) ?? firstLeafID(of: data.second)
        }
    }

    private static func collectLeafIDs(in node: SplitNode, into ids: inout [UUID]) {
        switch node {
        case let .leaf(id):
            ids.append(id)
        case let .split(data):
            collectLeafIDs(in: data.first, into: &ids)
            collectLeafIDs(in: data.second, into: &ids)
        }
    }

    private static func equalizeNode(_ node: SplitNode) -> SplitNode {
        switch node {
        case .leaf: node
        case let .split(data):
            .split(SplitData(
                direction: data.direction,
                ratio: 0.5,
                first: equalizeNode(data.first),
                second: equalizeNode(data.second)
            ))
        }
    }

    private static func remapNode(_ node: SplitNode, mapping: [UUID: UUID]) -> SplitNode {
        switch node {
        case let .leaf(id):
            .leaf(id: mapping[id] ?? id)
        case let .split(data):
            .split(SplitData(
                direction: data.direction,
                ratio: data.ratio,
                first: remapNode(data.first, mapping: mapping),
                second: remapNode(data.second, mapping: mapping)
            ))
        }
    }

    private static func resizeSplit(
        in node: SplitNode,
        leafID: UUID,
        direction: SplitDirection,
        amount: Double,
        bounds: CGSize,
        minSize: CGFloat
    ) -> SplitNode {
        switch node {
        case .leaf:
            return node
        case let .split(data):
            // Only adjust the split whose direction matches the drag and
            // whose subtree contains the dragged leaf on its `first` side.
            if data.direction == direction,
               containsLeaf(data.first, id: leafID)
            {
                let extent: CGFloat = switch direction {
                case .horizontal: bounds.width
                case .vertical: bounds.height
                }
                let safeExtent = max(extent, 1)
                let ratioDelta = amount / Double(safeExtent)
                let proposed = data.ratio + ratioDelta
                let minRatio = Double(minSize / safeExtent)
                let maxRatio = 1.0 - minRatio
                let newRatio = min(max(proposed, minRatio), maxRatio)
                return .split(SplitData(
                    direction: data.direction,
                    ratio: newRatio,
                    first: data.first,
                    second: data.second
                ))
            }
            return .split(SplitData(
                direction: data.direction,
                ratio: data.ratio,
                first: resizeSplit(
                    in: data.first,
                    leafID: leafID,
                    direction: direction,
                    amount: amount,
                    bounds: bounds,
                    minSize: minSize
                ),
                second: resizeSplit(
                    in: data.second,
                    leafID: leafID,
                    direction: direction,
                    amount: amount,
                    bounds: bounds,
                    minSize: minSize
                )
            ))
        }
    }

    static func containsLeaf(_ node: SplitNode, id: UUID) -> Bool {
        switch node {
        case let .leaf(leafID):
            leafID == id
        case let .split(data):
            containsLeaf(data.first, id: id) || containsLeaf(data.second, id: id)
        }
    }
}
