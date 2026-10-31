// KeyboardReturnOnDismiss.swift
// Weir — hands the keyboard back to the window's terminal as a sheet over it closes.

import SwiftUI

extension View {
    /// Gives the keyboard back to the focused pane of `window` once a sheet
    /// over it closes (a surface that closes leaves the keys with the
    /// terminal). AppKit gives the window back the first responder it had
    /// as the sheet opened, and that is often nothing a person can type
    /// into: the palette's field or a dropdown's list that opened the sheet
    /// and is gone now. A terminal or a field still in the window keeps
    /// the keys, since the person went there (`KeyboardHandoff.Keeper`).
    func returnsKeyboardOnDismiss(
        isPresented: Bool,
        window: WindowID,
        session: WorkspaceSession,
        registry: any SurfaceViewProviding
    ) -> some View {
        onChange(of: isPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            // On the next turn: the parent window is key again only once
            // the sheet's own window has ended.
            KeyboardHandoff.returnToFocusedPane(
                in: window,
                session: session,
                registry: registry,
                keeper: .terminalOrTextField,
                timing: .nextTurn
            )
        }
    }
}
