// SplitContainerView.swift
// Limpid — recursively renders a SplitNode tree. Uses ZStack + offset
// with absolute-position DragGesture (gesture.location) to eliminate
// divider-cursor drift that incremental-delta approaches suffer from.
// Pattern adapted from ghostty's SplitView.swift.

import SwiftUI

struct SplitContainerView: View {
    let node: SplitNode
    let ghosttyApp: GhosttyApp
    let onLeafFocus: (UUID) -> Void
    let onResize: (UUID, Double, SplitDirection, CGSize) -> Void

    private let dividerThickness: CGFloat = 6
    private let minPaneSize: CGFloat = 80

    var body: some View {
        switch node {
        case let .leaf(id):
            PaneContainerView(paneID: id, ghosttyApp: ghosttyApp)
                .onTapGesture { onLeafFocus(id) }
        case let .split(data):
            GeometryReader { geo in
                splitBody(data: data, size: geo.size)
            }
        }
    }

    @ViewBuilder
    private func splitBody(data: SplitData, size: CGSize) -> some View {
        let leftRect = leftRect(for: size, ratio: data.ratio, direction: data.direction)
        let rightRect = rightRect(for: size, leftRect: leftRect, direction: data.direction)
        let dividerCenter = dividerCenter(for: size, leftRect: leftRect, direction: data.direction)

        ZStack(alignment: .topLeading) {
            SplitContainerView(
                node: data.first,
                ghosttyApp: ghosttyApp,
                onLeafFocus: onLeafFocus,
                onResize: onResize
            )
            .frame(width: leftRect.width, height: leftRect.height)
            .offset(x: leftRect.origin.x, y: leftRect.origin.y)

            SplitContainerView(
                node: data.second,
                ghosttyApp: ghosttyApp,
                onLeafFocus: onLeafFocus,
                onResize: onResize
            )
            .frame(width: rightRect.width, height: rightRect.height)
            .offset(x: rightRect.origin.x, y: rightRect.origin.y)

            SplitDividerView(direction: data.direction == .horizontal ? .horizontal : .vertical)
                .position(dividerCenter)
                .gesture(dragGesture(data: data, size: size))
        }
    }

    private func dragGesture(data: SplitData, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                guard let firstLeafID = SplitTree.firstLeafID(of: data.first) else { return }
                let newRatio: Double
                switch data.direction {
                case .horizontal:
                    let clamped = min(max(minPaneSize, gesture.location.x), size.width - minPaneSize)
                    newRatio = Double(clamped / size.width)
                case .vertical:
                    let clamped = min(max(minPaneSize, gesture.location.y), size.height - minPaneSize)
                    newRatio = Double(clamped / size.height)
                }
                let currentExtent = data.direction == .horizontal ? Double(size.width) : Double(size.height)
                let delta = (newRatio - data.ratio) * currentExtent
                onResize(firstLeafID, delta, data.direction, size)
            }
    }

    private func leftRect(for size: CGSize, ratio: Double, direction: SplitDirection) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch direction {
        case .horizontal:
            rect.size.width = size.width * ratio - dividerThickness / 2
        case .vertical:
            rect.size.height = size.height * ratio - dividerThickness / 2
        }
        return rect
    }

    private func rightRect(for size: CGSize, leftRect: CGRect, direction: SplitDirection) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch direction {
        case .horizontal:
            rect.origin.x = leftRect.width + dividerThickness
            rect.size.width = size.width - rect.origin.x
        case .vertical:
            rect.origin.y = leftRect.height + dividerThickness
            rect.size.height = size.height - rect.origin.y
        }
        return rect
    }

    private func dividerCenter(for size: CGSize, leftRect: CGRect, direction: SplitDirection) -> CGPoint {
        switch direction {
        case .horizontal:
            CGPoint(x: leftRect.width + dividerThickness / 2, y: size.height / 2)
        case .vertical:
            CGPoint(x: size.width / 2, y: leftRect.height + dividerThickness / 2)
        }
    }
}
