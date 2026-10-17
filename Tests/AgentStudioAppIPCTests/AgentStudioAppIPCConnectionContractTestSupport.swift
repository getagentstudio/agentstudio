import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestHarness
import Foundation

enum IPCConnectionContractFact: Equatable, Sendable {
    case admitted
    case targetResolved
    case ended(AppIPCConnectionEndCause)
}

func makeConnectionContractFactSource() -> LocalFactSource<String, IPCConnectionContractFact> {
    LocalFactSource(
        vocabulary: FactVocabulary(
            describeScope: { $0 },
            describeFact: { String(describing: $0) },
            isClosing: { _, fact in
                if case .ended = fact { return true }
                return false
            }
        )
    )
}

/// These registrations exercise the server contract without depending on the
/// S3 service or registering any pane method in the production catalog.
func makeConnectionContractRegistration(
    name: String,
    execution: AppIPCMethodExecution = .inline,
    resolve: @escaping @Sendable () async throws -> Void = {},
    handler: @escaping @Sendable (AppIPCConnectionContext) async throws -> Void
) throws -> AnyAppIPCMethodRegistration {
    let descriptor = try TypedConnectionRegistrationFixture.preAuthenticationDescriptor(
        name: name,
        parameters: IPCEmptyParams(),
        result: IPCSystemPingResult(runtimeId: UUIDv7.generate())
    )
    return try AppIPCTypedMethodRegistration(
        descriptorRepresentations: IPCMethodDescriptorRepresentations(typedDescriptor: descriptor),
        correlation: AppIPCCorrelation<IPCEmptyParams>.notRequired,
        resolveTarget: { parameters, _, _ in
            try await resolve()
            return AppIPCTargetResolution(parameters: parameters, canonicalHandle: nil, target: .app)
        },
        connectionHandler: { _, context, _ in
            try await handler(context)
            return IPCSystemPingResult(runtimeId: context.contextId)
        },
        execution: execution
    ).erase()
}

func makeHeldConnectionRegistration(
    hold: HeldStep<AppIPCConnectionContext>,
    source: LocalFactSource<String, IPCConnectionContractFact>
) throws -> AnyAppIPCMethodRegistration {
    try makeConnectionContractRegistration(name: "fixture.waiting", execution: .waitsBesideReader) { context in
        source.sink("waiting", .admitted)
        do {
            try await hold.arrive(context)
        } catch is CancellationError {
            source.sink("waiting", .ended(context.connectionEndCause))
            return
        }
    }
}

func connectionContractRequest(_ method: String, id: Int) throws -> JSONRPCClientRequest {
    try JSONRPCClientRequest(id: .number(id), method: method, params: .object([:]))
}

/// Names a missing response in the runner-owned hang evidence. Every client
/// read uses the existing off-pool shim and is joined on success or failure.
func receiveConnectionContractReply(
    connection: UnixSocketConnection, named name: String
) async throws -> JSONRPCResponseMessage {
    let response = HeldStep<Result<JSONRPCResponseMessage, any Error>>(name)
    let read = Task {
        let result: Result<JSONRPCResponseMessage, any Error>
        do {
            var reader = TestFrameReader()
            let value = try await reader.receiveResponseWithoutBlockingMainActor(connection: connection)
            result = .success(value)
        } catch {
            result = .failure(error)
        }
        try? await response.arrive(result)
    }
    do {
        let value = try await response.firstArrival()
        response.release()
        await read.value
        return try value.get()
    } catch {
        connection.close()
        response.retire()
        await read.value
        throw error
    }
}
