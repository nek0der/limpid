// main.swift
// Limpid — authenticated LaunchAgent host for the Rust approval broker.

import Foundation

private final class AgentIntegrationConnection: NSObject, AgentIntegrationXPCProtocol {
    private let role: AgentIntegrationRole
    private let runID: UUID?
    private let session: RustApprovalSession

    init(role: AgentIntegrationRole, service: RustApprovalService) throws {
        self.role = role
        switch role {
        case .requester:
            let runID = UUID()
            self.runID = runID
            self.session = try service.requesterSession(runID: runID)
        case .controller:
            self.runID = nil
            self.session = try service.controllerSession()
        }
    }

    func openSession(withReply reply: @escaping (Data?, NSError?) -> Void) {
        do {
            let response = AgentIntegrationSessionBootstrap(
                role: role,
                runID: runID,
                serviceProcessID: ProcessInfo.processInfo.processIdentifier
            )
            try reply(JSONEncoder().encode(response), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func exchange(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void) {
        guard request.count <= AgentIntegrationConfiguration.maximumXPCRequestBytes else {
            reply(nil, AgentIntegrationError.invalidArguments(
                "The request exceeds the XPC size limit."
            ) as NSError)
            return
        }
        do {
            try reply(session.exchange(request), nil)
        } catch {
            reply(nil, error as NSError)
        }
    }
}

private final class AgentIntegrationListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let role: AgentIntegrationRole
    private let service: RustApprovalService

    init(role: AgentIntegrationRole, service: RustApprovalService) {
        self.role = role
        self.service = service
    }

    func listener(_: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        do {
            let exportedObject = try AgentIntegrationConnection(role: role, service: service)
            connection.exportedInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
            connection.exportedObject = exportedObject
            connection.activate()
            return true
        } catch {
            return false
        }
    }
}

private final class AgentIntegrationServiceRuntime {
    private let requesterListener: NSXPCListener
    private let controllerListener: NSXPCListener
    private let requesterDelegate: AgentIntegrationListenerDelegate
    private let controllerDelegate: AgentIntegrationListenerDelegate

    init() throws {
        let service = try RustApprovalService(maximumRecords: AgentIntegrationConfiguration.maximumRecords)
        requesterListener = NSXPCListener(
            machServiceName: AgentIntegrationConfiguration.requesterMachService
        )
        controllerListener = NSXPCListener(
            machServiceName: AgentIntegrationConfiguration.controllerMachService
        )
        requesterDelegate = AgentIntegrationListenerDelegate(role: .requester, service: service)
        controllerDelegate = AgentIntegrationListenerDelegate(role: .controller, service: service)

        // Foundation rejects mismatched peers before invoking either delegate,
        // so untrusted bytes never reach an exported object or the Rust decoder.
        try requesterListener.setConnectionCodeSigningRequirement(
            AgentIntegrationSigning.requirement(
                peerIdentifiers: AgentIntegrationConfiguration.requesterIdentifiers
            )
        )
        try controllerListener.setConnectionCodeSigningRequirement(
            AgentIntegrationSigning.requirement(
                peerIdentifiers: AgentIntegrationConfiguration.controllerIdentifiers
            )
        )
        requesterListener.delegate = requesterDelegate
        controllerListener.delegate = controllerDelegate
    }

    func run() -> Never {
        requesterListener.activate()
        controllerListener.activate()
        dispatchMain()
    }
}

do {
    try AgentIntegrationServiceRuntime().run()
} catch {
    FileHandle.standardError.write(Data("Agent Integration Service failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
