// MainWindowLayoutPlan.swift
// Limpid — resolves sidebar, tab, toolbar, and primary-content geometry from
// one window-width policy before the SwiftUI hierarchy renders those slots.

import CoreGraphics

/// One resolved layout and chrome assignment for the main window. Child views
/// render the assigned slots instead of independently interpreting persisted
/// sidebar state, compact overlay state, and tab orientation.
struct MainWindowLayoutPlan: Equatable {
    struct Input {
        let availableWidth: CGFloat
        let requestedSidebarWidth: CGFloat
        let requestedTabWidth: CGFloat
        let isSidebarHidden: Bool
        let isCompactSidebarPresented: Bool
        let isTabColumnHorizontal: Bool
        let isReviewPresented: Bool
    }

    enum TabOrientation: Equatable {
        case vertical
        case horizontal
    }

    enum SidebarPresentation: Equatable {
        case reserved(width: CGFloat)
        case overlay(width: CGFloat, isPresented: Bool)
        case hidden
    }

    enum ContainerIdentityPlacement: Equatable {
        case tabToolbar
        case terminalToolbar
    }

    let tabOrientation: TabOrientation
    let sidebarPresentation: SidebarPresentation
    let regularContainerIdentityPlacement: ContainerIdentityPlacement
    let regularToolbarMinimumWidth: CGFloat
    let tabColumnMinimumWidth: CGFloat
    let tabColumnMaximumWidth: CGFloat
    let tabColumnWidth: CGFloat
    let primaryContentWidth: CGFloat
    let horizontalToolbarLeadingInset: CGFloat

    var isSidebarPresented: Bool {
        switch sidebarPresentation {
        case .reserved:
            true
        case let .overlay(_, isPresented):
            isPresented
        case .hidden:
            false
        }
    }

    var sidebarWidth: CGFloat {
        switch sidebarPresentation {
        case let .reserved(width), let .overlay(width, _):
            width
        case .hidden:
            0
        }
    }

    var usesCompactSidebar: Bool {
        if case .overlay = sidebarPresentation {
            true
        } else {
            false
        }
    }

    var reservedSidebarWidth: CGFloat {
        if case let .reserved(width) = sidebarPresentation {
            width
        } else {
            0
        }
    }

    var isSidebarReserved: Bool {
        if case .reserved = sidebarPresentation {
            true
        } else {
            false
        }
    }

    var isCompactSidebarOverlayPresented: Bool {
        if case .overlay(_, true) = sidebarPresentation {
            true
        } else {
            false
        }
    }

    static func resolve(_ input: Input) -> MainWindowLayoutPlan {
        let orientation: TabOrientation = input.isTabColumnHorizontal ? .horizontal : .vertical
        let sidebarWidth = max(input.requestedSidebarWidth, LimpidLayout.sidebarMinWidth)
        // Preserve Review's file rail before reserving space for navigation.
        // Otherwise showing the sidebar at a narrow width immediately forces
        // the file rail into a second overlay.
        let primaryMinimum = input.isReviewPresented
            ? ReviewRail.inlineMinimumWidth
            : LimpidLayout.terminalColumnMinWidth
        let fullLayoutMinimum = sidebarWidth + primaryMinimum
            + (orientation == .vertical ? LimpidLayout.tabColumnMinWidth : 0)
        let usesCompactSidebar = input.availableWidth < fullLayoutMinimum
        let reservesSidebar = !input.isSidebarHidden && !usesCompactSidebar
        let reservedSidebarWidth = reservesSidebar ? sidebarWidth : 0

        let sidebarPresentation: SidebarPresentation = if reservesSidebar {
            .reserved(width: sidebarWidth)
        } else if usesCompactSidebar {
            .overlay(width: sidebarWidth, isPresented: input.isCompactSidebarPresented)
        } else {
            .hidden
        }

        let tabMinimum = orientation == .vertical ? LimpidLayout.tabColumnMinWidth : 0
        let maximumTabWidth: CGFloat = if orientation == .vertical {
            min(
                LimpidLayout.tabColumnMaxWidth,
                max(tabMinimum, input.availableWidth - reservedSidebarWidth - primaryMinimum)
            )
        } else {
            0
        }
        let tabColumnWidth: CGFloat = if orientation == .vertical {
            min(max(input.requestedTabWidth, tabMinimum), maximumTabWidth)
        } else {
            0
        }
        let primaryContentWidth = max(
            0,
            input.availableWidth - reservedSidebarWidth - tabColumnWidth
        )
        let horizontalToolbarLeadingInset = reservedSidebarWidth > 0
            ? reservedSidebarWidth
            : ContainerColumnFootprint.hiddenToolbarInset
        let regularContainerPlacement: ContainerIdentityPlacement = orientation == .vertical && reservesSidebar
            ? .tabToolbar
            : .terminalToolbar
        let regularToolbarMinimum = LimpidLayout.terminalToolbarFullWidth
            + (regularContainerPlacement == .terminalToolbar
                ? LimpidLayout.terminalToolbarContainerContextWidth
                : 0)
        return MainWindowLayoutPlan(
            tabOrientation: orientation,
            sidebarPresentation: sidebarPresentation,
            regularContainerIdentityPlacement: regularContainerPlacement,
            regularToolbarMinimumWidth: regularToolbarMinimum,
            tabColumnMinimumWidth: tabMinimum,
            tabColumnMaximumWidth: maximumTabWidth,
            tabColumnWidth: tabColumnWidth,
            primaryContentWidth: primaryContentWidth,
            horizontalToolbarLeadingInset: horizontalToolbarLeadingInset
        )
    }
}

/// X position of the container sidebar's right edge for the given
/// session. The sidebar starts at the window's leading edge, so its
/// width is the whole footprint.
enum ContainerColumnFootprint {
    /// Leading titlebar area occupied by traffic lights and the sidebar
    /// controls while the sidebar itself is absent. Horizontal tabs use this
    /// instead of reserving a nonexistent vertical tab column.
    static var hiddenToolbarInset: CGFloat {
        let controls = 2 * LimpidLayout.toolbarButtonWidth + 4
        let floatingToolbarRightEdge = LimpidLayout.trafficLightWidth + 10 + controls
        let toolbarGap: CGFloat = 12
        return floatingToolbarRightEdge + toolbarGap
    }
}
