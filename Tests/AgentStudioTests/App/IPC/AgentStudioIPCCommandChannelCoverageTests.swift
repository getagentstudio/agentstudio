import AgentStudioAppIPC
import AgentStudioIPCTransport
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore

/// S7: every `AppCommand` is callable through typed `command.execute` on the
/// debug channel, while stable and beta keep exactly today's admitted headless
/// surface.
@MainActor
@Suite("AgentStudio IPC command channel coverage", .serialized)
struct AgentStudioIPCCommandChannelCoverageTests {
    @Test("Pane context write privilege is classified by the command IPC projection")
    func paneContextMetadataRemainsClassified() throws {
        let base = AppCommand.newWindow.ipcSpec
        let spec = AppCommandIPCSpec(
            exposure: base.exposure, executionMode: base.executionMode,
            argumentVariants: base.argumentVariants, requiredPrivilege: .paneContextWrite,
            allowedTargetKinds: base.allowedTargetKinds, resultVariants: base.resultVariants,
            agentEligibility: base.agentEligibility)
        let input = spec.descriptorInput(definition: AppCommand.newWindow.definition, examples: [])
        #expect(input.dataScope == .paneContext)
        #expect(input.requiredPrivileges.contains(.paneContextWrite))
        #expect(IPCExecutionOwner.allCases.contains(.paneContextService))
        #expect(
            try JSONDecoder().decode(
                IPCExecutionOwner.self,
                from: JSONEncoder().encode(IPCExecutionOwner.paneContextService)) == .paneContextService)
    }

    /// The two example helpers split the variants between them. They are both
    /// exhaustive so a new variant is a build failure, and this pins the runtime
    /// half of that claim: no variant reaches a rejection instead of an example.
    @Test("every argument variant projects the example shape it names")
    func everyArgumentVariantProjectsItsOwnExample() throws {
        for variant in IPCCommandArgumentVariant.allCases {
            let arguments = try AgentStudioIPCCommandCatalogProjection.exampleArguments(for: variant)
            #expect(arguments.variant == variant, "\(variant.rawValue) projected a different shape")
        }
    }

    @Test("debug discovery exposes every AppCommand and labels the debug-only ones")
    func debugCatalogExposesEveryAppCommand() async throws {
        let harness = CommandAdapterHarness(channel: .debug)
        let catalog = try await makeIPCCommandCatalogOffMain(
            from: harness.adapter,
            channel: harness.channel
        )
        let ids = Set(catalog.commands.map(\.id.rawValue))

        #expect(catalog.commands.count == AppCommand.allCases.count)
        #expect(AppCommand.allCases.count == 154)
        for command in AppCommand.allCases {
            #expect(ids.contains(command.rawValue), "\(command.rawValue) missing from the debug catalog")
        }
        for descriptor in catalog.commands {
            let command = try #require(AppCommand(rawValue: descriptor.id.rawValue))
            #expect(descriptor.exposure == command.ipcSpec.exposure)
            #expect(Set(descriptor.argumentVariants) == Set(command.ipcSpec.argumentVariants))
            #expect(Set(descriptor.resultVariants) == Set(command.ipcSpec.resultVariants))
            #expect(!descriptor.examples.isEmpty)
        }
        let debugOnly = catalog.commands.filter { $0.exposure == .debugTesting }
        #expect(debugOnly.count == AppCommand.allCases.count - Self.admittedHeadlessCommands.count)
    }

    @Test(
        "stable and beta discovery admits the all-channel headless commands and the agent own-pane set",
        arguments: [AgentStudioIPCChannel.stable, .beta]
    )
    func admittedChannelCatalogStaysFrozen(channel: AgentStudioIPCChannel) async throws {
        let harness = CommandAdapterHarness(channel: channel)
        let catalog = try await makeIPCCommandCatalogOffMain(
            from: harness.adapter,
            channel: harness.channel
        )
        let ids = Set(catalog.commands.map(\.id.rawValue))

        #expect(catalog.commands.count == 24)
        #expect(ids == Set(Self.admittedHeadlessCommands.map(\.rawValue)))
        #expect(catalog.commands.allSatisfy { $0.exposure == .allChannels })
    }

    @Test("every AppCommand reaches an owner through the typed debug dispatch path")
    func everyAppCommandReachesAnOwnerOnDebug() async throws {
        let shell = RecordingShellCommandHandler(
            currentWindowId: AgentStudioIPCCommandCatalogProjection.ExampleIdentities.window)
        shell.defaultOutcome = .unsupportedCommand
        let workspaceOwner = RecordingWorkspaceIPCCommandHandler()
        let harness = CommandAdapterHarness(
            windowId: AgentStudioIPCCommandCatalogProjection.ExampleIdentities.window,
            channel: .debug,
            targetAuthorizer: PermissiveDurableTargetAuthorizer(),
            shellCommandHandler: shell
        )

        var unreached: [String] = []
        var mismatchedResults: [String] = []
        try await withIsolatedCommandDispatcher(
            configure: {
                AppCommandDispatcher.shared.handler = workspaceOwner
                AppCommandDispatcher.shared.appCommandRouter = shell
            },
            body: {
                for command in AppCommand.allCases {
                    for variant in command.ipcSpec.argumentVariants {
                        let request = try AgentStudioIPCCommandCatalogProjection.exampleRequest(
                            for: command, variant: variant)
                        let observedBefore = workspaceOwner.headlessRequests.count
                        do {
                            let result = try await harness.adapter.executeCommand(request, ownPaneAssertion: nil)
                            if !command.ipcSpec.resultVariants.contains(result.variant) {
                                mismatchedResults.append("\(command.rawValue):\(result.variant.rawValue)")
                            }
                            #expect(result.correlationId == request.correlationId)
                            #expect(result.commandId == request.commandId)
                        } catch {
                            unreached.append("\(command.rawValue):\(variant.rawValue) threw \(error)")
                            continue
                        }
                        guard workspaceOwner.headlessRequests.count > observedBefore,
                            let delivered = workspaceOwner.headlessRequests.last
                        else {
                            unreached.append("\(command.rawValue):\(variant.rawValue) reached no owner")
                            continue
                        }
                        // The owner must receive the command identity and the
                        // exact typed identities the wire supplied.
                        #expect(delivered.command == command)
                        #expect(delivered.arguments == .typedIPC(request.arguments))
                        #expect(delivered.executionContext == .headlessIPC(admitsDebugTestingCommands: true))
                    }
                }
            }
        )

        #expect(unreached.isEmpty, "Commands without a debug dispatch path: \(unreached)")
        #expect(mismatchedResults.isEmpty, "Results outside the declared variants: \(mismatchedResults)")
    }

    @Test(
        "stable and beta refuse every debug-only command before reaching an owner",
        arguments: [AgentStudioIPCChannel.stable, .beta]
    )
    func admittedChannelsRefuseDebugOnlyCommands(channel: AgentStudioIPCChannel) async throws {
        let shell = RecordingShellCommandHandler(
            currentWindowId: AgentStudioIPCCommandCatalogProjection.ExampleIdentities.window)
        shell.defaultOutcome = .unsupportedCommand
        let workspaceOwner = RecordingWorkspaceIPCCommandHandler()
        let harness = CommandAdapterHarness(
            windowId: AgentStudioIPCCommandCatalogProjection.ExampleIdentities.window,
            channel: channel,
            targetAuthorizer: PermissiveDurableTargetAuthorizer(),
            shellCommandHandler: shell
        )
        let debugOnly = AppCommand.allCases.filter { $0.ipcSpec.exposure == .debugTesting }

        var admitted: [String] = []
        try await withIsolatedCommandDispatcher(
            configure: {
                AppCommandDispatcher.shared.handler = workspaceOwner
                AppCommandDispatcher.shared.appCommandRouter = shell
            },
            body: {
                for command in debugOnly {
                    guard let variant = command.ipcSpec.argumentVariants.first else { continue }
                    let request = try AgentStudioIPCCommandCatalogProjection.exampleRequest(
                        for: command, variant: variant)
                    do {
                        _ = try await harness.adapter.executeCommand(request, ownPaneAssertion: nil)
                        admitted.append(command.rawValue)
                    } catch let error as AppIPCCommandError {
                        #expect(error.reason == .unsupportedCommand)
                    }
                }
            }
        )

        #expect(admitted.isEmpty, "Debug-only commands admitted on \(channel.rawValue): \(admitted)")
        #expect(workspaceOwner.headlessRequests.isEmpty)
        #expect(shell.handledRequests.isEmpty)
    }

    @Test("retired Panes organization commands report typed unavailable on debug")
    func retiredPanesOrganizationCommandsReportUnavailable() async throws {
        let windowId = AgentStudioIPCCommandCatalogProjection.ExampleIdentities.window
        let shell = RecordingShellCommandHandler(currentWindowId: windowId)
        shell.defaultOutcome = .unavailable(.featureUnavailable)
        let harness = CommandAdapterHarness(
            windowId: windowId,
            channel: .debug,
            targetAuthorizer: PermissiveDurableTargetAuthorizer(),
            shellCommandHandler: shell
        )
        let workspaceOwner = RecordingWorkspaceIPCCommandHandler()

        try await withIsolatedCommandDispatcher(
            configure: {
                AppCommandDispatcher.shared.handler = workspaceOwner
                AppCommandDispatcher.shared.appCommandRouter = shell
            },
            body: {
                for command in retiredPanesOrganizationCommands {
                    #expect(command.ipcSpec.resultVariants == [.unavailable])
                    let result = try await harness.adapter.executeCommand(
                        IPCCommandExecutionRequest(
                            commandId: .init(rawValue: command.rawValue),
                            correlationId: UUIDv7.generate(),
                            arguments: .workspaceWindow(.init(workspaceWindowId: windowId))
                        ), ownPaneAssertion: nil
                    )
                    #expect(result.variant == .unavailable)
                }
            }
        )
        #expect(workspaceOwner.headlessRequests.isEmpty)
    }

    @Test("the complete debug command catalog still fits the existing one MiB NDJSON frame")
    func debugCatalogFitsExistingFrame() async throws {
        let harness = CommandAdapterHarness(channel: .debug)
        let composition = try await makeIPCCommandCompositionOffMain(
            from: harness.adapter,
            channel: harness.channel
        )
        let catalog = composition.catalogResult
        let response = JSONRPCResponse.success(
            id: .number(1),
            result: try JSONRPCCodec.encodeJSONValue(composition.catalogResult)
        )
        let payload = try JSONRPCCodec.encodeResponse(response)
        let frameByteLimit = 1_048_576
        let frameByteCount = payload.utf8.count + 1

        #expect(catalog.commands.count == 154)
        #expect(
            frameByteCount <= frameByteLimit,
            "Complete 154-command debug catalog frame is \(frameByteCount) bytes"
        )
        let frame = try NDJSONFrameEncoder.encode(payload, maxFrameBytes: frameByteLimit)
        #expect(frame.count == frameByteCount)
    }

    static let admittedHeadlessCommands: [AppCommand] =
        [
            .zoomPane, .reloadBridgeWebView,
            .showReposSidebar, .showPanesSidebar,
            .setReposGroupingRepo, .setReposGroupingActivity,
            .setReposSortFieldName, .setReposSortFieldActivity,
            .toggleReposSortDirection,
            .toggleReposShowsPinned, .togglePanesShowsPinned,
            .pinRepo, .unpinRepo, .pinPane, .unpinPane, .focusSidebar,
        ] + agentOwnPaneCommands

    /// A1's own-pane command set; pane agents reach it on every channel.
    static let agentOwnPaneCommands: [AppCommand] = [
        .scrollToBottom, .scrollPageUp, .scrollPageDown,
        .scrollSmallStepUp, .scrollSmallStepDown,
        .jumpToPreviousPrompt, .jumpToNextPrompt, .closeDrawerPane,
    ]

    @Test("only the own-pane commands are agent eligible, and discovery reports each command's eligibility")
    func agentEligibilityMatchesTheOwnPaneSet() async throws {
        let ownPane = AppCommand.allCases.filter { $0.ipcSpec.agentEligibility == .ownPane }
        let anyTarget = AppCommand.allCases.filter { $0.ipcSpec.agentEligibility == .anyTarget }

        #expect(Set(ownPane) == Set(Self.agentOwnPaneCommands))
        #expect(anyTarget.isEmpty)
        #expect(ownPane.allSatisfy { $0.ipcSpec.exposure == .allChannels })

        let harness = CommandAdapterHarness(channel: .stable)
        let catalog = try await makeIPCCommandCatalogOffMain(
            from: harness.adapter,
            channel: harness.channel
        )
        for descriptor in catalog.commands {
            let command = try #require(AppCommand(rawValue: descriptor.id.rawValue))
            #expect(descriptor.agentEligibility == command.ipcSpec.agentEligibility)
        }
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)) as? [String: Any])
        let encodedCommands = try #require(encoded["commands"] as? [[String: Any]])
        let scrollToBottom = try #require(encodedCommands.first { $0["id"] as? String == "scrollToBottom" })
        let zoomPane = try #require(encodedCommands.first { $0["id"] as? String == "zoomPane" })
        #expect(scrollToBottom["agentEligibility"] as? String == "ownPane")
        #expect(zoomPane["agentEligibility"] as? String == "notYetAllowed")
    }
}

/// Authorizes every durable identity so coverage tests exercise dispatch and
/// owner delivery rather than workspace fixture construction. Target-rejection
/// behaviour has its own focused tests against the real authorizer.
@MainActor
final class PermissiveDurableTargetAuthorizer: WorkspaceDurableTargetAuthorizing {
    func containsRepository(id _: UUID) -> Bool { true }
    func containsTab(id _: UUID) -> Bool { true }
    func containsPane(id _: UUID) -> Bool { true }
    func containsWorktree(id _: UUID) -> Bool { true }
    func containsArrangement(tabId _: UUID, arrangementId _: UUID) -> Bool { true }
}
