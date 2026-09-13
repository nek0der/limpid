// AgentIntegrationServiceAlert.swift
// Limpid — actionable failure UI for native approval service activation.

import SwiftUI

private struct AgentIntegrationServiceAlertModifier: ViewModifier {
    let registrar: AgentIntegrationServiceRegistrar

    func body(content: Content) -> some View {
        content.alert(
            registrar.issue?.title ?? "",
            isPresented: Binding(
                get: { registrar.issue != nil },
                set: {
                    if !$0 {
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
        _ registrar: AgentIntegrationServiceRegistrar
    ) -> some View {
        modifier(AgentIntegrationServiceAlertModifier(registrar: registrar))
    }
}
