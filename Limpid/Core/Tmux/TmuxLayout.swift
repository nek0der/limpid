// TmuxLayout.swift
// Limpid — tmux's window layout string as a binary tree of cell rectangles, and its projection onto Limpid's split tree.

import Foundation

/// A rectangle in tmux's cell coordinates. `x` and `y` are absolute within
/// the window; tmux reserves one cell between siblings for its border, so
/// a sibling starts at the previous one's end plus one.
struct TmuxCellRect: Equatable {
    let width: Int
    let height: Int
    let x: Int
    let y: Int
}

/// One node of a tmux layout, already folded to binary. tmux flattens
/// same-axis splits, so its `{…}` and `[…]` containers hold any number of
/// children; we fold them to the right once, while parsing, so `{a,b,c}`
/// becomes `split(a, split(b, c))` and every consumer (the split tree, the
/// mirror's rectangles, a divider drag) walks the same shape. The fold
/// direction is fixed because the tree's shape is what `PaneSplitPath`
/// identifies a divider by: the same layout must always produce the same
/// paths.
indirect enum TmuxLayoutNode: Equatable {
    case pane(id: String, rect: TmuxCellRect)
    /// `first` ends where `gap` starts and `second` starts where it ends.
    /// `gap` is the border cell tmux leaves between them, spanning the
    /// split's full breadth. When the container had more than two
    /// children, `second` is a split over the remaining ones whose
    /// rectangle starts at the second child and ends with the container.
    case split(
        direction: SplitDirection,
        rect: TmuxCellRect,
        gap: TmuxCellRect,
        first: TmuxLayoutNode,
        second: TmuxLayoutNode
    )

    var rect: TmuxCellRect {
        switch self {
        case let .pane(_, rect), let .split(_, rect, _, _, _):
            rect
        }
    }

    /// Pane ids in layout order, `%N` form.
    ///
    /// Walked with an explicit stack rather than by recursion: a container
    /// tmux flattened folds to a tree as deep as it has children, and this
    /// runs on the control connection's routing queue, whose stack is far
    /// smaller than the main thread's.
    var paneIDs: [String] {
        var ids: [String] = []
        forEachPane { id, _ in ids.append(id) }
        return ids
    }

    /// Each pane's rectangle, keyed by its `%N` id.
    var paneRects: [String: TmuxCellRect] {
        var rects: [String: TmuxCellRect] = [:]
        forEachPane { rects[$0] = $1 }
        return rects
    }

    /// Every pane leaf in layout order. See `paneIDs` for why this is not
    /// written as a recursion.
    private func forEachPane(_ body: (String, TmuxCellRect) -> Void) {
        var stack = [self]
        while let node = stack.popLast() {
            switch node {
            case let .pane(id, rect):
                body(id, rect)
            case let .split(_, _, _, first, second):
                stack.append(second)
                stack.append(first)
            }
        }
    }

    /// The node at `path`, following `.first` / `.second` the way
    /// `PaneLayout` assigns paths to the folded tree.
    func node(at path: PaneSplitPath) -> TmuxLayoutNode? {
        var node = self
        for step in path {
            guard case let .split(_, _, _, first, second) = node else { return nil }
            node = step == .first ? first : second
        }
        return node
    }

    /// Fold one container's children to the right. `rect` is the box the
    /// children share; the remainder after the first child is the same
    /// box, started where the second child starts.
    ///
    /// Built from the last child backwards, so the tree's own depth costs
    /// no stack while it is made: the parser runs on the routing queue.
    /// `nil` for a container with no child, which tmux never writes.
    fileprivate static func fold(
        _ children: [TmuxLayoutNode],
        in rect: TmuxCellRect,
        direction: SplitDirection
    ) -> TmuxLayoutNode? {
        guard var second = children.last else { return nil }
        for index in stride(from: children.count - 2, through: 0, by: -1) {
            let first = children[index]
            let next = children[index + 1]
            let gap: TmuxCellRect
            switch direction {
            case .horizontal:
                let firstEnd = first.rect.x + first.rect.width
                gap = TmuxCellRect(width: next.rect.x - firstEnd, height: rect.height, x: firstEnd, y: rect.y)
            case .vertical:
                let firstEnd = first.rect.y + first.rect.height
                gap = TmuxCellRect(width: rect.width, height: next.rect.y - firstEnd, x: rect.x, y: firstEnd)
            }
            // The first level keeps the container's own box; every later one
            // is that box started where its first child starts.
            let box = index == 0 ? rect : Self.box(rect, startingAt: first.rect, direction: direction)
            second = .split(direction: direction, rect: box, gap: gap, first: first, second: second)
        }
        return second
    }

    private static func box(
        _ rect: TmuxCellRect,
        startingAt start: TmuxCellRect,
        direction: SplitDirection
    ) -> TmuxCellRect {
        switch direction {
        case .horizontal:
            TmuxCellRect(width: rect.x + rect.width - start.x, height: rect.height, x: start.x, y: rect.y)
        case .vertical:
            TmuxCellRect(width: rect.width, height: rect.y + rect.height - start.y, x: rect.x, y: start.y)
        }
    }
}

/// The value of `#{window_layout}` and the second field of `%layout-change`:
/// `<checksum>,<W>x<H>,<x>,<y>` followed by a pane id, `{children}`, or
/// `[children]`, recursively.
struct TmuxLayout: Equatable {
    let checksum: String
    let root: TmuxLayoutNode

    /// What a layout string may hold before we stop reading it. The string
    /// arrives on the control stream, which we do not write and cannot
    /// trust to describe a window that exists: without these, a run of
    /// digits overflows the integer arithmetic below and a run of brackets
    /// or of children makes a tree deeper than the routing queue's stack.
    /// A layout past any of them fails to parse, and the caller keeps the
    /// layout it had.
    enum Bound {
        /// Digits per field. tmux caps a window at 10000 cells per axis and
        /// numbers panes from zero, so five digits describe every field a
        /// real layout has; the sixth is headroom.
        static let digitCount = 6
        /// Nesting of `{…}` and `[…]`. tmux nests one level per change of
        /// split axis, and each level takes at least two cells of the axis
        /// it splits, so a window that may be 10000 cells tall cannot reach
        /// this.
        static let depth = 64
        /// Panes in one layout. A pane takes a cell and a border cell, so
        /// this is already far past what tmux can fit in a window; it is
        /// also far past what a tab could draw.
        static let paneCount = 500
    }

    static func parse(_ text: String) -> TmuxLayout? {
        var parser = Parser(text: Array(text.utf8))
        guard let checksum = parser.readChecksum(),
              let root = parser.readNode(),
              parser.isAtEnd
        else { return nil }
        return TmuxLayout(checksum: checksum, root: root)
    }

    /// Project onto Limpid's binary split tree, node for node. Ratios
    /// exclude the border cell so a cell count survives the round trip
    /// exactly.
    func paneNode(leafID: (String) -> UUID) -> PaneNode {
        Self.paneNode(root, leafID: leafID)
    }

    private static func paneNode(_ node: TmuxLayoutNode, leafID: (String) -> UUID) -> PaneNode {
        switch node {
        case let .pane(id, _):
            return .leaf(id: leafID(id))
        case let .split(direction, _, _, first, second):
            let firstExtent = direction == .horizontal ? first.rect.width : first.rect.height
            let secondExtent = direction == .horizontal ? second.rect.width : second.rect.height
            let total = firstExtent + secondExtent
            let ratio = total > 0 ? Double(firstExtent) / Double(total) : 0.5
            return .split(PaneSplit(
                direction: direction,
                ratio: ratio,
                first: paneNode(first, leafID: leafID),
                second: paneNode(second, leafID: leafID)
            ))
        }
    }

    // MARK: - Parser

    private struct Parser {
        let text: [UInt8]
        var index = 0
        /// Panes read so far, against `Bound.paneCount`.
        private var paneCount = 0

        init(text: [UInt8]) {
            self.text = text
        }

        var isAtEnd: Bool {
            index >= text.count
        }

        mutating func readChecksum() -> String? {
            let start = index
            while index < text.count, text[index] != 0x2C {
                index += 1
            }
            guard index < text.count, index > start else { return nil }
            let checksum = TmuxProtocol.lossyText(text[start..<index])
            index += 1
            return checksum
        }

        mutating func readNode(depth: Int = 0) -> TmuxLayoutNode? {
            guard depth <= Bound.depth else { return nil }
            guard let width = readInt(), consume(0x78),
                  let height = readInt(), consume(0x2C),
                  let x = readInt(), consume(0x2C),
                  let y = readInt()
            else { return nil }
            let rect = TmuxCellRect(width: width, height: height, x: x, y: y)

            guard index < text.count else { return nil }
            switch text[index] {
            case 0x2C:
                index += 1
                guard let pane = readInt() else { return nil }
                paneCount += 1
                guard paneCount <= Bound.paneCount else { return nil }
                return .pane(id: "%\(pane)", rect: rect)
            case 0x7B:
                return readContainer(rect, direction: .horizontal, open: 0x7B, close: 0x7D, depth: depth)
            case 0x5B:
                return readContainer(rect, direction: .vertical, open: 0x5B, close: 0x5D, depth: depth)
            default:
                return nil
            }
        }

        /// A container holds at least one child, so the fold always has a
        /// first node to start from; `{}` fails here like any other
        /// malformed input.
        private mutating func readContainer(
            _ rect: TmuxCellRect,
            direction: SplitDirection,
            open: UInt8,
            close: UInt8,
            depth: Int
        ) -> TmuxLayoutNode? {
            guard consume(open) else { return nil }
            var children: [TmuxLayoutNode] = []
            while true {
                guard let child = readNode(depth: depth + 1) else { return nil }
                children.append(child)
                if consume(close) {
                    break
                }
                guard consume(0x2C) else { return nil }
            }
            return TmuxLayoutNode.fold(children, in: rect, direction: direction)
        }

        /// A field of at most `Bound.digitCount` digits, so the running
        /// multiplication cannot overflow whatever the stream holds.
        private mutating func readInt() -> Int? {
            let start = index
            var value = 0
            while index < text.count, text[index] >= 0x30, text[index] <= 0x39 {
                guard index - start < Bound.digitCount else { return nil }
                value = value * 10 + Int(text[index] - 0x30)
                index += 1
            }
            return index > start ? value : nil
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard index < text.count, text[index] == byte else { return false }
            index += 1
            return true
        }
    }
}
