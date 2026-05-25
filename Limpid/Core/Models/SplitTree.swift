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

    /// `true` when `leafID` is present somewhere in the tree.
    func contains(leafID: UUID) -> Bool {
        guard let root else { return false }
        return Self.containsLeaf(root, id: leafID)
    }

    /// Nearest leaf adjacent to `leafID` in the requested direction, or
    /// nil. tmux-style: smallest gap along the direction axis, breaking
    /// ties by perpendicular center distance. Used by ⌥⌘←↑↓→.
    func neighborLeaf(of leafID: UUID, direction: SpatialDirection) -> UUID? {
        guard let root else { return nil }
        var rects: [(id: UUID, rect: CGRect)] = []
        Self.collectLeafRects(root, in: CGRect(x: 0, y: 0, width: 1, height: 1), into: &rects)
        guard let focused = rects.first(where: { $0.id == leafID })?.rect else { return nil }
        let candidates = rects.filter { $0.id != leafID }.filter { entry in
            switch direction {
            case .left:
                entry.rect.maxX <= focused.minX + 1e-6
                    && Self.overlaps(entry.rect.minY...entry.rect.maxY, focused.minY...focused.maxY)
            case .right:
                entry.rect.minX + 1e-6 >= focused.maxX
                    && Self.overlaps(entry.rect.minY...entry.rect.maxY, focused.minY...focused.maxY)
            case .up:
                entry.rect.maxY <= focused.minY + 1e-6
                    && Self.overlaps(entry.rect.minX...entry.rect.maxX, focused.minX...focused.maxX)
            case .down:
                entry.rect.minY + 1e-6 >= focused.maxY
                    && Self.overlaps(entry.rect.minX...entry.rect.maxX, focused.minX...focused.maxX)
            }
        }
        // Gap primary → perpendicular distance secondary. The primary
        // sort is what makes the 3-column case land on column 2, not 1.
        let focusedCenter = CGPoint(x: focused.midX, y: focused.midY)
        func axisGap(_ rect: CGRect) -> CGFloat {
            switch direction {
            case .left: focused.minX - rect.maxX
            case .right: rect.minX - focused.maxX
            case .up: focused.minY - rect.maxY
            case .down: rect.minY - focused.maxY
            }
        }
        func perpDistance(_ rect: CGRect) -> CGFloat {
            switch direction {
            case .left, .right: abs(rect.midY - focusedCenter.y)
            case .up, .down: abs(rect.midX - focusedCenter.x)
            }
        }
        return candidates.min { lhs, rhs in
            let gl = axisGap(lhs.rect)
            let gr = axisGap(rhs.rect)
            if gl != gr { return gl < gr }
            return perpDistance(lhs.rect) < perpDistance(rhs.rect)
        }?.id
    }

    private static func collectLeafRects(
        _ node: SplitNode,
        in bounds: CGRect,
        into rects: inout [(id: UUID, rect: CGRect)]
    ) {
        switch node {
        case let .leaf(id):
            rects.append((id, bounds))
        case let .split(data):
            switch data.direction {
            case .horizontal:
                let w1 = bounds.width * data.ratio
                let first = CGRect(x: bounds.minX, y: bounds.minY, width: w1, height: bounds.height)
                let second = CGRect(x: bounds.minX + w1, y: bounds.minY, width: bounds.width - w1, height: bounds.height)
                collectLeafRects(data.first, in: first, into: &rects)
                collectLeafRects(data.second, in: second, into: &rects)
            case .vertical:
                let h1 = bounds.height * data.ratio
                let first = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: h1)
                let second = CGRect(x: bounds.minX, y: bounds.minY + h1, width: bounds.width, height: bounds.height - h1)
                collectLeafRects(data.first, in: first, into: &rects)
                collectLeafRects(data.second, in: second, into: &rects)
            }
        }
    }

    private static func overlaps(_ a: ClosedRange<CGFloat>, _ b: ClosedRange<CGFloat>) -> Bool {
        a.lowerBound < b.upperBound - 1e-6 && b.lowerBound < a.upperBound - 1e-6
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
