// SplitTree.swift
// Limpid — immutable binary tree of pane leaves with ratio-based layout.
//
// A leaf holds a pane id; a split carries a direction, a divider ratio,
// and two children. The `Codable` form doubles as the on-disk session
// layout, so the case and property names below (`leaf` / `split` /
// `first` / `second` / `ratio` / `focusedLeafID`) are the persisted JSON
// keys — keep them stable when restoring an existing `state.json`.

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

// MARK: - PaneNode

indirect enum PaneNode: Codable, Equatable {
    case leaf(id: UUID)
    case split(PaneSplit)

    var leafID: UUID? {
        if case let .leaf(id) = self { return id }
        return nil
    }
}

// MARK: - PaneSplit

struct PaneSplit: Codable, Equatable {
    let direction: SplitDirection
    let ratio: Double
    let first: PaneNode
    let second: PaneNode

    init(direction: SplitDirection, ratio: Double, first: PaneNode, second: PaneNode) {
        self.direction = direction
        self.ratio = Self.clamped(ratio)
        self.first = first
        self.second = second
    }

    /// Synthesized `Codable` copies `ratio` straight from disk, bypassing the
    /// designated init's clamp. A tampered state.json could then carry a `NaN`
    /// or wildly out-of-range ratio and break the SwiftUI split layout, so we
    /// re-clamp on decode and fall back to a centered split for non-finite
    /// values.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        direction = try c.decode(SplitDirection.self, forKey: .direction)
        let rawRatio = try c.decode(Double.self, forKey: .ratio)
        ratio = rawRatio.isFinite ? Self.clamped(rawRatio) : 0.5
        first = try c.decode(PaneNode.self, forKey: .first)
        second = try c.decode(PaneNode.self, forKey: .second)
    }

    /// Smallest fraction either pane may occupy, so a divider can't be
    /// dragged past a pane's minimum visible width / height.
    static let minRatio = 0.1

    /// Constrain a divider ratio to `[minRatio, 1 - minRatio]`.
    static func clamped(_ ratio: Double) -> Double {
        max(minRatio, min(ratio, 1 - minRatio))
    }
}

// MARK: - SplitTree

struct SplitTree: Codable, Equatable {
    var root: PaneNode?
    var focusedLeafID: UUID?

    init(root: PaneNode? = nil, focusedLeafID: UUID? = nil) {
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

    /// The focused leaf, falling back to the first leaf when focus is
    /// unset. The single resolution every focus / navigation / swap path
    /// shares so an unfocused tree still maps to a concrete pane.
    var effectiveFocusedLeafID: UUID? {
        focusedLeafID ?? allLeafIDs().first
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
            .split(PaneSplit(
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
        let op = ResizeOp(
            leafID: leafID,
            direction: direction,
            amount: amount,
            bounds: bounds,
            minSize: minSize
        )
        return SplitTree(root: Self.resizeSplit(in: root, op: op), focusedLeafID: focusedLeafID)
    }

    /// Carries the per-call inputs through the recursive resize walk so
    /// the helper stays under the 5-parameter cap.
    private struct ResizeOp {
        let leafID: UUID
        let direction: SplitDirection
        let amount: Double
        let bounds: CGSize
        let minSize: CGFloat
    }

    /// Reset every split in the tree to a 50/50 ratio.
    func equalize() -> SplitTree {
        guard let root else { return self }
        return SplitTree(
            root: Self.equalizeNode(root),
            focusedLeafID: focusedLeafID
        )
    }

    /// Equalize only the subtree whose divider matches `direction` and
    /// whose `first` subtree's first leaf is `leafID`. Other branches
    /// stay at whatever ratio they were dragged to. Mirrors the
    /// addressing used by `resize` so a divider's drag handle and its
    /// double-click handle resolve to the same split node.
    ///
    /// Ambiguity caveat (matches `resize`): a tree like
    /// `H(H(A, C), B)` — created by splitting A right twice while
    /// holding focus on A — has the same `firstLeafID(of: data.first)`
    /// for both H dividers. The topmost match wins, so double-clicking
    /// the inner divider in that shape rebalances the outer. The
    /// right-leaning shape that "split right, focus the new pane, split
    /// right again" produces has unambiguous addresses, so the typical
    /// power user flow is unaffected.
    func equalize(at leafID: UUID, direction: SplitDirection) -> SplitTree {
        guard let root else { return self }
        return SplitTree(
            root: Self.equalizeAt(in: root, leafID: leafID, direction: direction),
            focusedLeafID: focusedLeafID
        )
    }

    /// Swap the positions of two leaves: each slot keeps its geometry
    /// (every ancestor split's orientation + ratio is untouched) and only
    /// the two leaves' ids trade places. Because a live surface is keyed
    /// by leaf id, the panes visually swap while the layout stays put —
    /// the tmux `swap-pane` model. Focus moves
    /// to `a` (the pane the caller is swapping), so it follows that pane
    /// into its new slot. No-op when the ids match or either is absent.
    func swappingLeaves(_ a: UUID, _ b: UUID) -> SplitTree {
        guard a != b, let root, contains(leafID: a), contains(leafID: b) else { return self }
        return SplitTree(
            root: Self.remapNode(root, mapping: [a: b, b: a]),
            focusedLeafID: a
        )
    }

    /// Which edge of the target leaf to insert against.
    enum InsertSide {
        case left, right, top, bottom
    }

    /// Detach `sourceLeafID` from wherever it currently lives in the
    /// tree and re-insert it next to `targetLeafID` on the given side.
    /// A side-by-side insert (`left`/`right`) creates a horizontal split,
    /// a stacked insert (`top`/`bottom`) creates a vertical split; the
    /// new split's ratio is 0.5 so the two panes share the slot equally.
    /// No-op when either id is missing or the two are the same.
    func inserting(
        _ sourceLeafID: UUID,
        beside targetLeafID: UUID,
        on side: InsertSide
    ) -> SplitTree {
        guard sourceLeafID != targetLeafID,
              let root,
              contains(leafID: sourceLeafID),
              contains(leafID: targetLeafID)
        else { return self }

        // 1. Detach the source from its current slot. `removeLeaf`
        // collapses the abandoned parent split for us.
        let (pruned, _) = Self.removeLeaf(in: root, id: sourceLeafID)
        guard let prunedRoot = pruned else { return self }

        // 2. Replace the target leaf with a fresh split whose two
        // children are (source, target) in the order dictated by side.
        let direction: SplitDirection = (side == .left || side == .right) ? .horizontal : .vertical
        let sourceNode = PaneNode.leaf(id: sourceLeafID)
        let targetNode = PaneNode.leaf(id: targetLeafID)
        let (first, second): (PaneNode, PaneNode) = (side == .left || side == .top)
            ? (sourceNode, targetNode)
            : (targetNode, sourceNode)
        let inserted = Self.replaceLeaf(in: prunedRoot, leafID: targetLeafID) { _ in
            .split(PaneSplit(
                direction: direction,
                ratio: 0.5,
                first: first,
                second: second
            ))
        }

        return SplitTree(root: inserted, focusedLeafID: sourceLeafID)
    }

    /// Walk `node` and rebuild it with the leaf identified by `leafID`
    /// substituted by whatever `replacement` returns. Returns `node`
    /// unchanged when the leaf isn't found.
    private static func replaceLeaf(
        in node: PaneNode,
        leafID: UUID,
        with replacement: (UUID) -> PaneNode
    ) -> PaneNode {
        switch node {
        case let .leaf(id):
            id == leafID ? replacement(id) : node
        case let .split(data):
            .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: replaceLeaf(in: data.first, leafID: leafID, with: replacement),
                second: replaceLeaf(in: data.second, leafID: leafID, with: replacement)
            ))
        }
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
        _ node: PaneNode,
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
        in node: PaneNode,
        id targetID: UUID,
        with replacement: (PaneNode) -> PaneNode
    ) -> PaneNode {
        switch node {
        case let .leaf(id) where id == targetID:
            replacement(node)
        case .leaf:
            node
        case let .split(data):
            .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: replaceLeaf(in: data.first, id: targetID, with: replacement),
                second: replaceLeaf(in: data.second, id: targetID, with: replacement)
            ))
        }
    }

    private static func removeLeaf(
        in node: PaneNode,
        id targetID: UUID
    ) -> (PaneNode?, UUID?) {
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
                    .split(PaneSplit(
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

    static func firstLeafID(of node: PaneNode) -> UUID? {
        switch node {
        case let .leaf(id): id
        case let .split(data):
            firstLeafID(of: data.first) ?? firstLeafID(of: data.second)
        }
    }

    private static func collectLeafIDs(in node: PaneNode, into ids: inout [UUID]) {
        switch node {
        case let .leaf(id):
            ids.append(id)
        case let .split(data):
            collectLeafIDs(in: data.first, into: &ids)
            collectLeafIDs(in: data.second, into: &ids)
        }
    }

    private static func equalizeNode(_ node: PaneNode) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case let .split(data):
            // Weight by leaf count in the same axis so every leaf along that
            // axis ends up equal width / height — `H(A, H(B, C))` lands as
            // `|1|1|1|`, not `|1/2|1/4|1/4|`. Mirrors ghostty's algorithm at
            // `vendor/ghostty/src/datastruct/split_tree.zig:759`. `PaneSplit`'s
            // `clamped(_:)` floors the ratio at `0.1`, so trees with > 9
            // same-axis leaves trade some equality for the divider-min
            // invariant — a deliberate corner-case sacrifice.
            let weightLeft = weight(data.first, sameDirection: data.direction)
            let weightRight = weight(data.second, sameDirection: data.direction)
            let total = weightLeft + weightRight
            let ratio = total > 0
                ? Double(weightLeft) / Double(total)
                : 0.5
            return .split(PaneSplit(
                direction: data.direction,
                ratio: ratio,
                first: equalizeNode(data.first),
                second: equalizeNode(data.second)
            ))
        }
    }

    /// Count leaves under `node` that are reachable through splits of the
    /// same `direction`. Crossing into a perpendicular split caps the
    /// subtree at one unit because that subtree's ratio is decided by its
    /// own axis, not the caller's.
    private static func weight(_ node: PaneNode, sameDirection: SplitDirection) -> Int {
        switch node {
        case .leaf:
            return 1
        case let .split(data):
            guard data.direction == sameDirection else { return 1 }
            return weight(data.first, sameDirection: sameDirection)
                + weight(data.second, sameDirection: sameDirection)
        }
    }

    /// Walk the tree, equalize the first split whose divider matches the
    /// `(leafID, direction)` address (same convention as `resizeSplit`),
    /// and recurse into both children otherwise.
    private static func equalizeAt(
        in node: PaneNode,
        leafID: UUID,
        direction: SplitDirection
    ) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case let .split(data):
            if data.direction == direction,
               firstLeafID(of: data.first) == leafID
            {
                return equalizeNode(node)
            }
            return .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: equalizeAt(in: data.first, leafID: leafID, direction: direction),
                second: equalizeAt(in: data.second, leafID: leafID, direction: direction)
            ))
        }
    }

    private static func remapNode(_ node: PaneNode, mapping: [UUID: UUID]) -> PaneNode {
        switch node {
        case let .leaf(id):
            .leaf(id: mapping[id] ?? id)
        case let .split(data):
            .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: remapNode(data.first, mapping: mapping),
                second: remapNode(data.second, mapping: mapping)
            ))
        }
    }

    private static func resizeSplit(in node: PaneNode, op: ResizeOp) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case let .split(data):
            // Only adjust the split whose direction matches the drag and
            // whose subtree contains the dragged leaf on its `first` side.
            if data.direction == op.direction,
               containsLeaf(data.first, id: op.leafID)
            {
                let extent: CGFloat = switch op.direction {
                case .horizontal: op.bounds.width
                case .vertical: op.bounds.height
                }
                let safeExtent = max(extent, 1)
                let ratioDelta = op.amount / Double(safeExtent)
                let proposed = data.ratio + ratioDelta
                let minRatio = Double(op.minSize / safeExtent)
                let maxRatio = 1.0 - minRatio
                let newRatio = min(max(proposed, minRatio), maxRatio)
                return .split(PaneSplit(
                    direction: data.direction,
                    ratio: newRatio,
                    first: data.first,
                    second: data.second
                ))
            }
            return .split(PaneSplit(
                direction: data.direction,
                ratio: data.ratio,
                first: resizeSplit(in: data.first, op: op),
                second: resizeSplit(in: data.second, op: op)
            ))
        }
    }

    static func containsLeaf(_ node: PaneNode, id: UUID) -> Bool {
        switch node {
        case let .leaf(leafID):
            leafID == id
        case let .split(data):
            containsLeaf(data.first, id: id) || containsLeaf(data.second, id: id)
        }
    }
}
