// SplitContainerView.swift
// Limpid — recursively renders a SplitNode tree using GeometryReader to
// hand each child its half of the available space.

import SwiftUI

struct SplitContainerView: View {
    let node: SplitNode
    let ghosttyApp: GhosttyApp
    let onLeafFocus: (UUID) -> Void
    let onResize: (UUID, Double, SplitDirection, CGSize) -> Void

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
        if let firstLeafID = SplitTree.firstLeafID(of: data.first) {
            let firstExtent = data.direction == .horizontal
                ? size.width * data.ratio
                : size.height * data.ratio

            switch data.direction {
            case .horizontal:
                HStack(spacing: 0) {
                    SplitContainerView(
                        node: data.first,
                        ghosttyApp: ghosttyApp,
                        onLeafFocus: onLeafFocus,
                        onResize: onResize
                    )
                    .frame(width: max(firstExtent, 0))
                    SplitDividerView(direction: .horizontal) { delta in
                        onResize(firstLeafID, delta, .horizontal, size)
                    }
                    SplitContainerView(
                        node: data.second,
                        ghosttyApp: ghosttyApp,
                        onLeafFocus: onLeafFocus,
                        onResize: onResize
                    )
                }
            case .vertical:
                VStack(spacing: 0) {
                    SplitContainerView(
                        node: data.first,
                        ghosttyApp: ghosttyApp,
                        onLeafFocus: onLeafFocus,
                        onResize: onResize
                    )
                    .frame(height: max(firstExtent, 0))
                    SplitDividerView(direction: .vertical) { delta in
                        onResize(firstLeafID, delta, .vertical, size)
                    }
                    SplitContainerView(
                        node: data.second,
                        ghosttyApp: ghosttyApp,
                        onLeafFocus: onLeafFocus,
                        onResize: onResize
                    )
                }
            }
        } else {
            let _: Void = {
                assertionFailure("SplitData.first has no leaf — tree is malformed")
            }()
        }
    }
}
