// AgentIntegrationXPCProtocol.swift
// Limpid — role-separated discrete-message XPC contract.

import Foundation

@objc protocol AgentIntegrationXPCProtocol {
    func openSession(withReply reply: @escaping (Data?, NSError?) -> Void)
    func exchange(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)
}
