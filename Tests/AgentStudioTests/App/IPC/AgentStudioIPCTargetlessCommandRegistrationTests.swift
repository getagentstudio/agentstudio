import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTestSupport
import Foundation
import Testing

@testable import AgentStudio

@MainActor
@Suite("App IPC targetless command registration", .serialized)
struct AgentStudioIPCTargetlessCommandRegistrationTests {
    init() { installTestCoreAtomsIfNeeded() }

    @Test("showInboxNotifications reaches the real shell owner through command.execute")
    func inboxCommandReachesRealShellOwnerThroughRegistration() async throws {
        let shellOwner = AppDelegate()
        let workspaceStore = WorkspaceStore()
        let adapter = AgentStudioIPCCommandAdapter(
            workspaceId: workspaceStore.identityAtom.workspaceId,
            channel: .debug,
            targetAuthorizer: WorkspaceDurableTargetAuthorizationPort(workspaceStore: workspaceStore),
            shellCommandHandler: shellOwner
        )
        let composition = try await makeIPCCommandCompositionOffMain(from: adapter, channel: .debug)
        let registration = try executeRegistration(composition: composition, adapter: adapter)
        let request = IPCCommandExecutionRequest(
            commandId: .init(rawValue: AppCommand.showInboxNotifications.rawValue),
            correlationId: UUIDv7.generate(),
            arguments: .noArguments
        )

        let result = try await withIsolatedCommandDispatcher(
            configure: {
                AppCommandDispatcher.shared.handler = nil
                AppCommandDispatcher.shared.appCommandRouter = shellOwner
            },
            body: {
                try await invoke(registration, request: request)
            }
        )

        #expect(
            result
                == .unavailable(
                    .init(
                        commandId: request.commandId, correlationId: request.correlationId, reason: .featureUnavailable)
                )
        )
    }

    @Test("every exposed targetless command executes its catalog examples through the real registration")
    func targetlessCatalogExamplesPassRegistrationTargetValidation() async throws {
        let harness = CommandAdapterHarness(channel: .debug)
        let composition = try await makeIPCCommandCompositionOffMain(from: harness.adapter, channel: harness.channel)
        let registration = try executeRegistration(composition: composition, adapter: harness.adapter)
        let targetlessCommands = try composition.catalogResult.commands.filter { descriptor in
            let command = try #require(AppCommand(rawValue: descriptor.id.rawValue))
            return command.ipcSpec.allowedTargetKinds.isEmpty
        }
        #expect(!targetlessCommands.isEmpty)

        try await withRawCommandAdapterDispatcher(harness: harness) {
            for descriptor in targetlessCommands {
                let command = try #require(AppCommand(rawValue: descriptor.id.rawValue))
                #expect(descriptor.allowedTargetKinds.isEmpty)
                #expect(!descriptor.examples.isEmpty, "Missing catalog example for \(descriptor.id.rawValue)")
                // Existing recording owner isolates registration conformance from
                // window creation and presentation. Real-owner Inbox proof is above.
                harness.shellCommandHandler.outcomeByCommand[command] =
                    RecordingWorkspaceIPCCommandHandler.declaredOutcome(for: command)
                for example in descriptor.examples {
                    do {
                        let result = try await invoke(registration, request: example.request)
                        #expect(descriptor.resultVariants.contains(result.variant))
                        #expect(result.commandId == example.request.commandId)
                        #expect(result.correlationId == example.request.correlationId)
                    } catch {
                        Issue.record(
                            error,
                            "\(descriptor.id.rawValue): catalog example must pass target validation and reach a declared result"
                        )
                    }
                }
            }
        }
    }

    private func executeRegistration(
        composition: IPCCommandMethodComposition, adapter: AgentStudioIPCCommandAdapter
    ) throws -> AnyAppIPCMethodRegistration {
        try #require(
            AppIPCCommandMethodRegistrations.make(composition: composition, port: adapter).first {
                $0.descriptor.metadata.name == "command.execute"
            }
        )
    }

    private func invoke(
        _ registration: AnyAppIPCMethodRegistration, request: IPCCommandExecutionRequest
    ) async throws -> IPCCommandExecutionResult {
        let parameters = try JSONRPCCodec.encodeJSONValue(IPCRawCommandExecutionRequest(typedRequest: request))
        let context = AppIPCConnectionContext(
            contextId: UUIDv7.generate(), channel: .debug,
            authenticatedContext: .init(
                principal: commandAdapterTestPrincipal(),
                credentialIdentity: .diagnostic(generationID: UUIDv7.generate())
            ),
            authenticate: { _ in .unauthenticated }, authenticationStatus: { .unauthenticated },
            eventSubscriber: TargetlessCommandUnusedEventSubscriber()
        )
        let result = try await registration.invoke(
            parameters: parameters, connectionContext: context,
            targetResolutionTools: .init(canonicalizePaneHandle: { _ in throw IPCHandleError.targetNotFound }),
            authorize: { _, _ in }
        )
        let resultData: Data
        switch result {
        case .value(let value): resultData = try JSONEncoder().encode(value)
        case .encoded(let bytes): resultData = bytes
        }
        return try JSONDecoder().decode(IPCCommandExecutionResult.self, from: resultData)
    }
}

private struct TargetlessCommandUnusedEventSubscriber: IPCEventSubscriber {
    func deliver(_: String) async throws -> IPCEventDeliveryResult { .delivered }
}
