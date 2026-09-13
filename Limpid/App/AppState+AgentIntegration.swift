// AppState+AgentIntegration.swift
// Limpid — coordinates approval routing with service reconciliation readiness.

extension AppState {
    func startAgentIntegration() {
        agentIntegrationServiceRegistrar.start { [weak approvalPresentation] isReady in
            if isReady {
                approvalPresentation?.start()
            } else {
                approvalPresentation?.stop()
            }
        }
    }
}
