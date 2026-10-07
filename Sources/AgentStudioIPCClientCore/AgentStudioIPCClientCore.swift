import AgentStudioIPCTransport
import AgentStudioProgrammaticControl
import Foundation

package struct AgentStudioIPCClient: Sendable {
    package let configuration: AgentStudioIPCClientConfiguration
    private let descriptors: [IPCAnyMethodDescriptor]
    private let onCallCompletion: @Sendable (IPCCLIStoreReadThrough?) -> Void
    private let deadline: CallDeadline?

    package init(
        configuration: AgentStudioIPCClientConfiguration,
        descriptors: [IPCAnyMethodDescriptor],
        deadline: CallDeadline? = nil,
        onCallCompletion: @escaping @Sendable (IPCCLIStoreReadThrough?) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.descriptors = descriptors
        self.deadline = deadline
        self.onCallCompletion = onCallCompletion
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
        try withAuthenticatedExchange(first: invocation, requestID: requestID) { exchange in
            try exchange.call(invocation)
        }
    }

    /// One connection, login and original deadline serve every dependent step.
    /// The connection closes when this synchronous scope ends.
    package func withAuthenticatedExchange<Output>(
        first invocation: IPCDescriptorInvocation, requestID: Int = 1,
        _ body: (inout IPCAuthenticatedExchange) throws -> Output
    ) throws -> Output {
        guard invocation.descriptor.metadata.responseDelivery == .single else {
            throw failure(.notSubmitted, .localRequestEncoding)
        }
        let prepared = try prepareExchange(invocation, requestID: requestID)
        let connection = try connect()
        var readThrough: IPCCLIStoreReadThrough?
        defer {
            connection.close()
            onCallCompletion(readThrough)
        }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        readThrough = try authenticateIfNeeded(prepared, connection: connection, reader: &reader)
        var exchange = IPCAuthenticatedExchange(
            owner: self, connection: connection, reader: reader,
            requestID: prepared.commandRequestID, firstInvocation: invocation, firstFrame: prepared.commandFrame,
            readThrough: readThrough)
        defer { readThrough = exchange.readThrough }
        return try body(&exchange)
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
        var readThrough: IPCCLIStoreReadThrough?
        defer {
            connection.close()
            onCallCompletion(readThrough)
        }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        readThrough = try authenticateIfNeeded(exchange, connection: connection, reader: &reader)
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

    /// The bundled app has already validated its catalog. Preserve its bytes
    /// for explicit discovery; typed reads are only for consumers of metadata.
    package func discoverCatalogBytes(requestID: Int = 1) throws -> Data {
        try callDiscovery(method: "system.capabilities", requestID: requestID)
    }

    package func discoverCatalog(requestID: Int = 1) throws -> IPCMethodCatalogResult {
        let encodedResult = try discoverCatalogBytes(requestID: requestID)
        do {
            return try JSONDecoder().decode(IPCMethodCatalogResult.self, from: encodedResult)
        } catch {
            throw failure(.deliveryUncertain, .invalidTypedResult)
        }
    }

    package func discoverCommandBytes(requestID: Int = 1) throws -> Data {
        try callDiscovery(method: "command.list", requestID: requestID)
    }

    /// Both explicit discovery methods share the same authenticated exchange.
    private func callDiscovery(method: String, requestID: Int) throws -> Data {
        let authentication = try authenticationExchange(requestID: requestID, forMethod: method)
        let commandID = authentication == nil ? requestID : requestID + 1
        let frame: Data
        do {
            frame = try NDJSONFrameEncoder.encode(
                JSONRPCCodec.encodeRequest(
                    JSONRPCClientRequest(id: .number(commandID), method: method, params: .object([:]))
                ), maxFrameBytes: configuration.maxRequestFrameBytes
            )
        } catch { throw failure(.notSubmitted, .localRequestEncoding) }
        let exchange = PreparedDescriptorExchange(
            commandFrame: frame, commandRequestID: commandID, authentication: authentication
        )
        let connection = try connect()
        var readThrough: IPCCLIStoreReadThrough?
        defer {
            connection.close()
            onCallCompletion(readThrough)
        }
        var reader = AgentStudioIPCClientFrameReader(maxFrameBytes: configuration.maxResponseFrameBytes)
        readThrough = try authenticateIfNeeded(exchange, connection: connection, reader: &reader)
        try submit(frame, connection: connection)
        let responseFrame: String
        do { responseFrame = try reader.receiveFrame(connection: connection) } catch {
            throw failure(.deliveryUncertain, .commandResponseMissing)
        }
        let response: JSONRPCDiscoveryResponse
        do { response = try JSONRPCCodec.decodeDiscoveryResponse(responseFrame) } catch {
            throw failure(.deliveryUncertain, .invalidResponse)
        }
        guard response.id == .number(commandID) else { throw failure(.deliveryUncertain, .responseIDMismatch) }
        if let error = response.error {
            throw IPCDescriptorRemoteFailureDecoder.decode(error, descriptor: nil)
        }
        guard let result = response.resultBytes else {
            throw failure(.deliveryUncertain, .invalidResponse)
        }
        return result
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
    ) throws -> IPCCLIStoreReadThrough? {
        guard let authentication = exchange.authentication else { return nil }
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
        guard case .authenticated(_, _, _, let readThrough) = status else {
            throw failure(.authenticationRejected, .authenticationResponse)
        }
        return readThrough
    }

    fileprivate func normalizedResponse(
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
            return try UnixSocketClient.connect(
                endpoint: UnixSocketEndpoint(path: configuration.socketPath), deadline: deadline)
        } catch let error as UnixSocketTransportError where error.reason == .connectFailed {
            throw failure(.endpointUnavailableBeforeSubmission, .endpointConnectFailed(errnoCode: error.errnoCode))
        } catch let error as UnixSocketTransportError {
            throw failure(.notSubmitted, .endpointConnectFailed(errnoCode: error.errnoCode))
        } catch { throw failure(.notSubmitted, .localRequestEncoding) }
    }

    fileprivate func submit(_ frame: Data, connection: UnixSocketConnection) throws {
        do { try connection.send(frame) } catch { throw failure(.notSubmitted, .commandWrite) }
    }

    fileprivate func receiveResponse(
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

/// A scoped sequential exchange over the client's existing framing and validation.
package struct IPCAuthenticatedExchange {
    private let owner: AgentStudioIPCClient
    private let connection: UnixSocketConnection
    private var reader: AgentStudioIPCClientFrameReader
    private var nextRequestID: Int
    private var firstRequest: (invocation: IPCDescriptorInvocation, frame: Data)?
    fileprivate var readThrough: IPCCLIStoreReadThrough?

    fileprivate init(
        owner: AgentStudioIPCClient, connection: UnixSocketConnection, reader: AgentStudioIPCClientFrameReader,
        requestID: Int, firstInvocation: IPCDescriptorInvocation, firstFrame: Data,
        readThrough: IPCCLIStoreReadThrough?
    ) {
        self.owner = owner
        self.connection = connection
        self.reader = reader
        nextRequestID = requestID
        firstRequest = (firstInvocation, firstFrame)
        self.readThrough = readThrough
    }

    package mutating func call(_ invocation: IPCDescriptorInvocation) throws -> IPCDescriptorClientCallResult {
        guard invocation.descriptor.metadata.responseDelivery == .single,
            nextRequestID > 0, nextRequestID < Int.max
        else { throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .localRequestEncoding) }
        let requestID = nextRequestID
        nextRequestID += 1
        let frame: Data
        if let first = firstRequest {
            guard first.invocation.descriptor.metadata.name == invocation.descriptor.metadata.name,
                first.invocation.normalizedParameters.data == invocation.normalizedParameters.data
            else { throw IPCDescriptorClientFailure(disposition: .notSubmitted, reason: .localRequestEncoding) }
            frame = first.frame
            firstRequest = nil
        } else {
            frame = try NDJSONFrameEncoder.encode(
                owner.requestFrame(invocation, requestID: requestID),
                maxFrameBytes: owner.configuration.maxRequestFrameBytes)
        }
        try owner.submit(frame, connection: connection)
        let response = try owner.receiveResponse(id: requestID, connection: connection, reader: &reader)
        let result = try owner.normalizedResponse(response, descriptor: invocation.descriptor, requestID: requestID)
        if invocation.descriptor.metadata.name == "auth.login", case .success(let success) = result {
            let status = try JSONDecoder().decode(IPCAuthStatusResult.self, from: success.normalizedResult.data)
            if case .authenticated(_, _, _, let mark) = status { readThrough = mark }
        }
        return result
    }
}
