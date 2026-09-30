import AgentStudioProgrammaticControl
import Foundation

package struct IPCDescriptorClientResponse: Sendable {
    package let descriptor: IPCAnyMethodDescriptor
    package let requestID: Int
    package let normalizedResult: IPCValidatedJSON
}

package enum IPCDescriptorClientCallResult: Sendable {
    case success(IPCDescriptorClientResponse)
    case remoteFailure(IPCDescriptorRemoteFailure)
}

package enum IPCDescriptorClientStreamFrame: Sendable {
    case initialResponse(IPCDescriptorClientResponse)
    case notification(String)
    case remoteFailure(IPCDescriptorRemoteFailure)
}

package struct IPCDescriptorRemoteFailure: Error, Sendable {
    package let code: Int
    package let documentedReason: String?
    package let correction: IPCSchemaValidationError?
    package let requiredScope: IPCPermissionScope?
    package let agentRefusal: IPCAgentRefusal?
}

/// The app refused a pane agent by name. Only the two agent outcomes and a
/// method or command identifier are kept; nothing else from the remote error.
package struct IPCAgentRefusal: Equatable, Sendable {
    package enum Reason: String, Equatable, Sendable {
        case notYetAllowed
        case refusedForAgent
    }

    package let reason: Reason
    /// The refused method or command identifier.
    package let name: String
}

package struct IPCDescriptorClientFailure: Error, Equatable, Sendable {
    package enum Disposition: Equatable, Sendable {
        case notSubmitted
        case endpointUnavailableBeforeSubmission
        case authenticationRejected
        case protocolRejected
        case deliveryUncertain
    }

    package enum Reason: Equatable, Sendable {
        case socketNotFound
        case endpointConnectFailed(errnoCode: Int32)
        case localRequestEncoding
        case authenticationTransport
        case authenticationResponse
        case commandWrite
        case commandResponseMissing
        case responseIDMismatch
        case invalidResponse
        case invalidTypedResult
        case unsupportedVersion(IPCSchemaValidationError)
    }

    package let disposition: Disposition
    package let reason: Reason
}
