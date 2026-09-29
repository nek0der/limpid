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
    /// The sidebar keeps its physical width independent of visibility so the
    /// offscreen drawer retains stable geometry throughout its movement.
    /// Reservation remains a separate concern through `reservedSidebarWidth`.
    let sidebarWidth: CGFloat
    let regularContainerIdentityPlacement: ContainerIdentityPlacement
    let regularToolbarMinimumWidth: CGFloat
    let tabColumnMinimumWidth: CGFloat
    let tabColumnMaximumWidth: CGFloat
    /// Width of the vertical tab column below the toolbar; 0 with
    /// horizontal tabs, which live in a bar instead.
    let tabColumnWidth: CGFloat
    /// Width of the tab segment in the toolbar, which holds the container
    /// title and New Tab. It is the same for both orientations, so switching
    /// between them moves only the tab list and leaves the toolbar in place.
    let tabToolbarWidth: CGFloat
    let primaryContentWidth: CGFloat

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

    /// Leading-edge travel for the sidebar surface. Keeping this
    /// independent from reservation lets the content columns resize without
    /// changing the drawer's travel distance.
    var sidebarLeadingOffset: CGFloat {
        isSidebarPresented ? 0 : -sidebarWidth
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
        // Horizontal tabs have no column, but their toolbar keeps the same
        // tab segment, so both orientations need the same width.
        let fullLayoutMinimum = sidebarWidth + primaryMinimum + LimpidLayout.tabColumnMinWidth
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

        let tabMinimum = LimpidLayout.tabColumnMinWidth
        let maximumTabWidth = min(
            LimpidLayout.tabColumnMaxWidth,
            max(tabMinimum, input.availableWidth - reservedSidebarWidth - primaryMinimum)
        )
        let tabToolbarWidth = min(max(input.requestedTabWidth, tabMinimum), maximumTabWidth)
        let tabColumnWidth: CGFloat = orientation == .vertical ? tabToolbarWidth : 0
        let primaryContentWidth = max(
            0,
            input.availableWidth - reservedSidebarWidth - tabColumnWidth
        )
        let regularContainerPlacement: ContainerIdentityPlacement = reservesSidebar
            ? .tabToolbar
            : .terminalToolbar
        let regularToolbarMinimum = LimpidLayout.terminalToolbarFullWidth
            + (regularContainerPlacement == .terminalToolbar
                ? LimpidLayout.terminalToolbarContainerContextWidth
                : 0)
        return MainWindowLayoutPlan(
            tabOrientation: orientation,
            sidebarPresentation: sidebarPresentation,
            sidebarWidth: sidebarWidth,
            regularContainerIdentityPlacement: regularContainerPlacement,
            regularToolbarMinimumWidth: regularToolbarMinimum,
            tabColumnMinimumWidth: tabMinimum,
            tabColumnMaximumWidth: maximumTabWidth,
            tabColumnWidth: tabColumnWidth,
            tabToolbarWidth: tabToolbarWidth,
            primaryContentWidth: primaryContentWidth
        )
    }
}
