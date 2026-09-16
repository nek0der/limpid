// TmuxLayout.swift
// Limpid — tmux's window layout string as a tree of cell rectangles, and its projection onto Limpid's split tree.

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

/// One node of a tmux layout. tmux flattens same-axis splits, so a container
/// holds any number of children; Limpid's binary `PaneNode` is derived from
/// it by `TmuxLayout.paneNode`.
indirect enum TmuxLayoutNode: Equatable {
    case pane(id: String, rect: TmuxCellRect)
    /// Children left to right: the `{…}` form.
    case sideBySide(rect: TmuxCellRect, children: [TmuxLayoutNode])
    /// Children top to bottom: the `[…]` form.
    case stacked(rect: TmuxCellRect, children: [TmuxLayoutNode])

    var rect: TmuxCellRect {
        switch self {
        case let .pane(_, rect), let .sideBySide(rect, _), let .stacked(rect, _):
            rect
        }
    }

    /// Pane ids in layout order, `%N` form.
    var paneIDs: [String] {
        switch self {
        case let .pane(id, _):
            [id]
        case let .sideBySide(_, children), let .stacked(_, children):
            children.flatMap(\.paneIDs)
        }
    }
}

/// The value of `#{window_layout}` and the second field of `%layout-change`:
/// `<checksum>,<W>x<H>,<x>,<y>` followed by a pane id, `{children}`, or
/// `[children]`, recursively.
struct TmuxLayout: Equatable {
    let checksum: String
    let root: TmuxLayoutNode

    static func parse(_ text: String) -> TmuxLayout? {
        var parser = Parser(text: Array(text.utf8))
        guard let checksum = parser.readChecksum(),
              let root = parser.readNode(),
              parser.isAtEnd
        else { return nil }
        return TmuxLayout(checksum: checksum, root: root)
    }

    /// Project onto Limpid's binary split tree. tmux lets any number of
    /// siblings share one axis; we fold them to the right, so `{a,b,c}`
    /// becomes `H(a, H(b, c))`. The fold direction is fixed because the
    /// tree's shape is what `PaneSplitPath` identifies a divider by: the
    /// same layout must always produce the same paths. Ratios exclude the
    /// border cell so a cell count survives the round trip exactly.
    func paneNode(leafID: (String) -> UUID) -> PaneNode {
        Self.fold(root, leafID: leafID)
    }

    private static func fold(_ node: TmuxLayoutNode, leafID: (String) -> UUID) -> PaneNode {
        switch node {
        case let .pane(id, _):
            .leaf(id: leafID(id))
        case let .sideBySide(rect, children):
            foldSiblings(children, of: rect, direction: .horizontal, leafID: leafID)
        case let .stacked(rect, children):
            foldSiblings(children, of: rect, direction: .vertical, leafID: leafID)
        }
    }

    private static func foldSiblings(
        _ children: [TmuxLayoutNode],
        of rect: TmuxCellRect,
        direction: SplitDirection,
        leafID: (String) -> UUID
    ) -> PaneNode {
        guard let first = children.first else {
            // tmux never emits an empty container; treating it as an empty
            // pane keeps the projection total without inventing structure.
            return .leaf(id: leafID(""))
        }
        guard children.count > 1 else { return fold(first, leafID: leafID) }
        let rest = Array(children.dropFirst())

        let firstExtent: Int
        let restExtent: Int
        let restRect: TmuxCellRect
        switch direction {
        case .horizontal:
            firstExtent = first.rect.width
            let restX = rest[0].rect.x
            restRect = TmuxCellRect(width: rect.x + rect.width - restX, height: rect.height, x: restX, y: rect.y)
            restExtent = restRect.width
        case .vertical:
            firstExtent = first.rect.height
            let restY = rest[0].rect.y
            restRect = TmuxCellRect(width: rect.width, height: rect.y + rect.height - restY, x: rect.x, y: restY)
            restExtent = restRect.height
        }
        let total = firstExtent + restExtent
        let ratio = total > 0 ? Double(firstExtent) / Double(total) : 0.5

        let second: PaneNode = if rest.count == 1 {
            fold(rest[0], leafID: leafID)
        } else {
            foldSiblings(rest, of: restRect, direction: direction, leafID: leafID)
        }
        return .split(PaneSplit(direction: direction, ratio: ratio, first: fold(first, leafID: leafID), second: second))
    }

    // MARK: - Parser

    private struct Parser {
        let text: [UInt8]
        var index = 0

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

        mutating func readNode() -> TmuxLayoutNode? {
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
                return .pane(id: "%\(pane)", rect: rect)
            case 0x7B:
                guard let children = readChildren(open: 0x7B, close: 0x7D) else { return nil }
                return .sideBySide(rect: rect, children: children)
            case 0x5B:
                guard let children = readChildren(open: 0x5B, close: 0x5D) else { return nil }
                return .stacked(rect: rect, children: children)
            default:
                return nil
            }
        }

        private mutating func readChildren(open: UInt8, close: UInt8) -> [TmuxLayoutNode]? {
            guard consume(open) else { return nil }
            var children: [TmuxLayoutNode] = []
            while true {
                guard let child = readNode() else { return nil }
                children.append(child)
                if consume(close) {
                    return children
                }
                guard consume(0x2C) else { return nil }
            }
        }

        private mutating func readInt() -> Int? {
            let start = index
            var value = 0
            while index < text.count, text[index] >= 0x30, text[index] <= 0x39 {
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
