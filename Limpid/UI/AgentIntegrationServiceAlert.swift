// AgentIntegrationServiceAlert.swift
// Limpid — actionable failure UI for native approval service activation.

import SwiftUI

private struct AgentIntegrationServiceAlertModifier: ViewModifier {
    let registrar: AgentIntegrationServiceRegistrar
    /// Whether this window shows the alert: one window does, not every one.
    let isShown: Bool

    func body(content: Content) -> some View {
        content.alert(
            Text(registrar.issue?.title ?? ""),
            isPresented: Binding(
                get: { isShown && registrar.issue != nil },
                set: {
                    // Only this window's own dismissal: one the alert left
                    // for another window is not an answer.
                    if !$0, isShown {
                        registrar.dismissIssue()
                    }
                }
            ),
            presenting: registrar.issue
        ) { issue in
            if issue.reason == .requiresApproval {
                Button("Open Login Items") {
                    registrar.openLoginItemsSettings()
                }
            }
            Button("Retry") {
                registrar.retry()
            }
            Button("Not Now", role: .cancel) {
                registrar.dismissIssue()
            }
        } message: { issue in
            Text(issue.detail)
        }
    }
}

extension View {
    func agentIntegrationServiceAlert(
        _ registrar: AgentIntegrationServiceRegistrar,
        isShown: Bool
    ) -> some View {
        modifier(AgentIntegrationServiceAlertModifier(registrar: registrar, isShown: isShown))
    }
}
