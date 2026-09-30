import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package struct AgentStudioIPCClient: Sendable {
    package let configuration: AgentStudioIPCClientConfiguration
    private let descriptors: [IPCAnyMethodDescriptor]

    package init(configuration: AgentStudioIPCClientConfiguration, descriptors: [IPCAnyMethodDescriptor]) {
        self.configuration = configuration
        self.descriptors = descriptors
    }

    package func requestFrame(_ invocation: IPCDescriptorInvocation, requestID: Int = 1) throws -> String {
        do {
            let parameters = try invocation.normalizedParameters.data(
                validatedFor: invocation.descriptor.metadata.parameterSchema
            )
            return try JSONRPCCodec.encodeRequest(
                JSONRPCClientRequest(
                    id: .number(requestID),
                    method: invocation.descriptor.metadata.name,
                    params: JSONDecoder().decode(JSONValue.self, from: parameters)
                )
            )
        } catch {
            throw failure(.notSubmitted, .localRequestEncoding)
        }
    }

    package func call(_ invocation: IPCDescriptorInvocation, requestID: Int = 1) throws
        -> IPCDescriptorClientCallResult
    {
        guard invocation.descriptor.metadata.responseDelivery == .single else {
            throw failure(.notSubmitted, .localRequestEncoding)
        }
        let exchange = try prepareExchange(invocation, requestID: requestID)
        let connection = try connect()
        defer { connection.close() }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        try authenticateIfNeeded(exchange, connection: connection, reader: &reader)
        try submit(exchange.commandFrame, connection: connection)
        let response = try receiveResponse(id: exchange.commandRequestID, connection: connection, reader: &reader)
        return try normalizedResponse(response, descriptor: invocation.descriptor, requestID: exchange.commandRequestID)
    }

    package func stream(
        _ invocation: IPCDescriptorInvocation,
        requestID: Int = 1,
        onFrame: (IPCDescriptorClientStreamFrame) throws -> Void
    ) throws {
        guard invocation.descriptor.metadata.responseDelivery == .subscription else {
            throw failure(.notSubmitted, .localRequestEncoding)
        }
        let exchange = try prepareExchange(invocation, requestID: requestID)
        let connection = try connect()
        defer { connection.close() }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        try authenticateIfNeeded(exchange, connection: connection, reader: &reader)
        try submit(exchange.commandFrame, connection: connection)
        let initial = try receiveResponse(id: exchange.commandRequestID, connection: connection, reader: &reader)
        switch try normalizedResponse(initial, descriptor: invocation.descriptor, requestID: exchange.commandRequestID)
        {
        case .success(let response):
            try onFrame(.initialResponse(response))
        case .remoteFailure(let remoteFailure):
            try onFrame(.remoteFailure(remoteFailure))
            return
        }
        while true {
            let frame: String
            do {
                frame = try reader.receiveFrame(connection: connection)
            } catch let error as AgentStudioIPCClientError where error.reason == .emptyResponse {
                return
            } catch {
                throw failure(.deliveryUncertain, .invalidResponse)
            }
            if (try? JSONRPCCodec.decodeResponse(frame)) != nil {
                throw failure(.deliveryUncertain, .responseIDMismatch)
            }
            do {
                let notification = try JSONRPCCodec.decodeRequest(frame)
                guard notification.id == nil else { throw failure(.deliveryUncertain, .responseIDMismatch) }
            } catch let error as IPCDescriptorClientFailure {
                throw error
            } catch {
                throw failure(.deliveryUncertain, .invalidResponse)
            }
            try onFrame(.notification(frame))
        }
    }

    /// Discovery has a concrete metadata decoder; received metadata never creates an invocable descriptor.
    package func discoverCatalog(requestID: Int = 1) throws -> IPCMethodCatalogResult {
        let authentication = try authenticationExchange(requestID: requestID, forMethod: "system.capabilities")
        let commandID = authentication == nil ? requestID : requestID + 1
        let frame: Data
        do {
            frame = try NDJSONFrameEncoder.encode(
                JSONRPCCodec.encodeRequest(
                    JSONRPCClientRequest(id: .number(commandID), method: "system.capabilities", params: .object([:]))
                ), maxFrameBytes: configuration.maxRequestFrameBytes
            )
        } catch { throw failure(.notSubmitted, .localRequestEncoding) }
        let exchange = PreparedDescriptorExchange(
            commandFrame: frame, commandRequestID: commandID, authentication: authentication
        )
        let connection = try connect()
        defer { connection.close() }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        try authenticateIfNeeded(exchange, connection: connection, reader: &reader)
        try submit(frame, connection: connection)
        let response = try receiveResponse(id: commandID, connection: connection, reader: &reader)
        if let error = response.error {
            throw IPCDescriptorRemoteFailureDecoder.decode(error, descriptor: nil)
        }
        guard let result = response.result else {
            throw failure(.deliveryUncertain, .invalidResponse)
        }
        do {
            return try IPCMethodCatalogDecoder.decode(JSONEncoder().encode(result))
        } catch let correction as IPCSchemaValidationError
            where
            correction.fieldPath == "$.compatibility" && correction.reason == .invalidValue
        {
            throw failure(.protocolRejected, .unsupportedVersion(correction))
        } catch {
            throw failure(.deliveryUncertain, .invalidTypedResult)
        }
    }

    private func prepareExchange(_ invocation: IPCDescriptorInvocation, requestID: Int) throws
        -> PreparedDescriptorExchange
    {
        let authentication = try authenticationExchange(
            requestID: requestID, forMethod: invocation.descriptor.metadata.name)
        let commandID = authentication == nil ? requestID : requestID + 1
        do {
            return try PreparedDescriptorExchange(
                commandFrame: NDJSONFrameEncoder.encode(
                    requestFrame(invocation, requestID: commandID), maxFrameBytes: configuration.maxRequestFrameBytes
                ), commandRequestID: commandID, authentication: authentication
            )
        } catch { throw failure(.notSubmitted, .localRequestEncoding) }
    }

    private func authenticationExchange(requestID: Int, forMethod method: String) throws -> DescriptorAuthentication? {
        guard requestID > 0, requestID < Int.max else { throw failure(.notSubmitted, .localRequestEncoding) }
        guard let token = configuration.authToken, method != "auth.login" else { return nil }
        let matches = descriptors.filter { $0.metadata.name == "auth.login" }
        guard matches.count == 1, let descriptor = matches.first else {
            throw failure(.notSubmitted, .authenticationResponse)
        }
        do {
            let parameters = try descriptor.normalizeParameters(JSONEncoder().encode(IPCAuthLoginParams(token: token)))
            let invocation = IPCDescriptorInvocation(
                descriptor: descriptor, normalizedParameters: parameters, presentation: .tooling)
            return try DescriptorAuthentication(
                descriptor: descriptor,
                requestID: requestID,
                frame: NDJSONFrameEncoder.encode(
                    requestFrame(invocation, requestID: requestID), maxFrameBytes: configuration.maxRequestFrameBytes
                )
            )
        } catch { throw failure(.notSubmitted, .authenticationResponse) }
    }

    private func authenticateIfNeeded(
        _ exchange: PreparedDescriptorExchange,
        connection: UnixSocketConnection,
        reader: inout AgentStudioIPCClientFrameReader
    ) throws {
        guard let authentication = exchange.authentication else { return }
        let response: JSONRPCResponseMessage
        do {
            try connection.send(authentication.frame)
            response = try receiveResponse(id: authentication.requestID, connection: connection, reader: &reader)
        } catch { throw failure(.notSubmitted, .authenticationTransport) }
        guard response.error == nil else { throw failure(.authenticationRejected, .authenticationResponse) }
        let status: IPCAuthStatusResult
        do {
            guard let result = response.result else { throw failure(.notSubmitted, .authenticationResponse) }
            let normalized = try authentication.descriptor.normalizeResult(JSONEncoder().encode(result))
            let data = try normalized.data(validatedFor: authentication.descriptor.metadata.resultSchema)
            status = try JSONDecoder().decode(IPCAuthStatusResult.self, from: data)
        } catch { throw failure(.notSubmitted, .authenticationResponse) }
        guard case .authenticated = status else { throw failure(.authenticationRejected, .authenticationResponse) }
    }

    private func normalizedResponse(
        _ response: JSONRPCResponseMessage, descriptor: IPCAnyMethodDescriptor, requestID: Int
    ) throws -> IPCDescriptorClientCallResult {
        if let error = response.error {
            return .remoteFailure(
                IPCDescriptorRemoteFailureDecoder.decode(
                    error,
                    descriptor: descriptor
                )
            )
        }
        do {
            guard let result = response.result else { throw failure(.deliveryUncertain, .invalidResponse) }
            return try .success(
                IPCDescriptorClientResponse(
                    descriptor: descriptor, requestID: requestID,
                    normalizedResult: descriptor.normalizeResult(JSONEncoder().encode(result))
                ))
        } catch { throw failure(.deliveryUncertain, .invalidTypedResult) }
    }

    private func connect() throws -> UnixSocketConnection {
        do {
            return try UnixSocketClient.connect(endpoint: UnixSocketEndpoint(path: configuration.socketPath))
        } catch let error as UnixSocketTransportError where error.reason == .connectFailed {
            throw failure(.endpointUnavailableBeforeSubmission, .endpointConnectFailed(errnoCode: error.errnoCode))
        } catch { throw failure(.notSubmitted, .localRequestEncoding) }
    }

    private func submit(_ frame: Data, connection: UnixSocketConnection) throws {
        do { try connection.send(frame) } catch { throw failure(.deliveryUncertain, .commandWrite) }
    }

    private func receiveResponse(
        id: Int, connection: UnixSocketConnection, reader: inout AgentStudioIPCClientFrameReader
    ) throws -> JSONRPCResponseMessage {
        let frame: String
        do { frame = try reader.receiveFrame(connection: connection) } catch {
            throw failure(.deliveryUncertain, .commandResponseMissing)
        }
        let response: JSONRPCResponseMessage
        do { response = try JSONRPCCodec.decodeResponse(frame) } catch {
            throw failure(.deliveryUncertain, .invalidResponse)
        }
        guard response.id == .number(id) else { throw failure(.deliveryUncertain, .responseIDMismatch) }
        return response
    }

    private func failure(
        _ disposition: IPCDescriptorClientFailure.Disposition, _ reason: IPCDescriptorClientFailure.Reason
    )
        -> IPCDescriptorClientFailure
    {
        IPCDescriptorClientFailure(disposition: disposition, reason: reason)
    }
}

private struct DescriptorAuthentication {
    let descriptor: IPCAnyMethodDescriptor
    let requestID: Int
    let frame: Data
}

private struct PreparedDescriptorExchange {
    let commandFrame: Data
    let commandRequestID: Int
    let authentication: DescriptorAuthentication?
}

private struct AgentStudioIPCClientFrameReader {
    private let maxFrameBytes: Int
    private var decoder: NDJSONFrameDecoder
    private var queuedFrames: [String] = []

    init(maxFrameBytes: Int) {
        self.maxFrameBytes = maxFrameBytes
        decoder = NDJSONFrameDecoder(maxFrameBytes: maxFrameBytes)
    }

    mutating func receiveFrame(connection: UnixSocketConnection) throws -> String {
        while queuedFrames.isEmpty {
            let data = try connection.receive(maxBytes: min(maxFrameBytes, 16_384))
            guard !data.isEmpty else { throw AgentStudioIPCClientError(reason: .emptyResponse) }
            queuedFrames.append(contentsOf: try decoder.append(data))
        }
        return queuedFrames.removeFirst()
    }
}
