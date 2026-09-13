// AgentIntegrationXPCClient.swift
// Limpid — authenticated client for one role-specific integration endpoint.

import Foundation

final class AgentIntegrationXPCClient {
    private let connection: NSXPCConnection
    private let timeoutSeconds: Int

    init(role: AgentIntegrationRole, timeoutSeconds: Int = 5) throws {
        guard timeoutSeconds > 0 else {
            throw AgentIntegrationError.invalidArguments("The XPC timeout must be positive.")
        }
        let machService = switch role {
        case .requester: AgentIntegrationConfiguration.requesterMachService
        case .controller: AgentIntegrationConfiguration.controllerMachService
        }
        let connection = NSXPCConnection(machServiceName: machService, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: (any AgentIntegrationXPCProtocol).self)
        try connection.setCodeSigningRequirement(AgentIntegrationSigning.requirement(
            peerIdentifiers: [AgentIntegrationConfiguration.serviceIdentifier]
        ))
        connection.activate()
        self.connection = connection
        self.timeoutSeconds = timeoutSeconds
    }

    deinit {
        connection.invalidate()
    }

    func openSession() throws -> AgentIntegrationSessionBootstrap {
        let response = try call { proxy, reply in
            proxy.openSession(withReply: reply)
        }
        return try JSONDecoder().decode(AgentIntegrationSessionBootstrap.self, from: response)
    }

    func exchange(_ request: Data) throws -> Data {
        guard request.count <= AgentIntegrationConfiguration.maximumXPCRequestBytes else {
            throw AgentIntegrationError.invalidArguments("The request exceeds the XPC size limit.")
        }
        let response = try call { proxy, reply in
            proxy.exchange(request, withReply: reply)
        }
        guard response.count <= AgentIntegrationConfiguration.maximumXPCResponseBytes else {
            throw AgentIntegrationError.invalidResponse
        }
        return response
    }

    private func call(
        _ body: (any AgentIntegrationXPCProtocol, @escaping (Data?, NSError?) -> Void) -> Void
    ) throws -> Data {
        let result = AgentIntegrationResultBox<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            result.set(.failure(AgentIntegrationError.requestFailed(error.localizedDescription)))
            semaphore.signal()
        }) as? any AgentIntegrationXPCProtocol else {
            throw AgentIntegrationError.invalidResponse
        }
        body(proxy) { data, error in
            if let error {
                result.set(.failure(AgentIntegrationError.requestFailed(error.localizedDescription)))
            } else if let data {
                result.set(.success(data))
            } else {
                result.set(.failure(AgentIntegrationError.invalidResponse))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .seconds(timeoutSeconds)) == .success else {
            throw AgentIntegrationError.timeout
        }
        return try result.get()
    }
}

private final class AgentIntegrationResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?

    func set(_ result: Result<Value, any Error>) {
        lock.withLock {
            guard self.result == nil else { return }
            self.result = result
        }
    }

    func get() throws -> Value {
        try lock.withLock {
            guard let result else { throw AgentIntegrationError.invalidResponse }
            return try result.get()
        }
    }
}
