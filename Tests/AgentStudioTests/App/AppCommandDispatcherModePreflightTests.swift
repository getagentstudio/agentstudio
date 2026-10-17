import Foundation
import Testing

@testable import AgentStudio
@testable import AgentStudioCore
@testable import AgentStudioInfrastructure
@testable import AgentStudioTestSupport

@MainActor
@Suite("App command dispatcher mode preflight")
struct AppCommandDispatcherModePreflightTests {
    @Test("keyboard Cmd+R admits a probe while programmatic dispatch does not")
    func keyboardCommandRefreshAdmitsProbeOnlyAtKeyboardIngress() async throws {
        let clock = CommandRefreshProbeClock(nowNanoseconds: 1_000_000)
        let recorder = CommandRefreshProbeRecorder()
        let probe = AgentStudioInteractionPerformanceProbe(
            nowNanoseconds: clock.now,
            recordDuration: recorder.record
        )
        let shellOwner = RecordingDispatcherShellCommandOwner(executionResult: true)
        var admittedCorrelationIds: [UUID] = []

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = shellOwner
                configuration.interactionProbe = probe
                configuration.commandRefreshAccepted = {
                    admittedCorrelationIds.append($0)
                }
            },
            body: { dispatcher in
                dispatcher.dispatchKeyboardShortcut(.toggleManagementLayer)
                dispatcher.dispatch(.toggleManagementLayer)

                #expect(admittedCorrelationIds.count == 1)
                #expect(recorder.records.isEmpty)
                #expect(
                    shellOwner.interactions.filter {
                        $0 == .contextualExecution(command: .toggleManagementLayer)
                    }.count == 2
                )
            }
        )
    }

    // Mutation caught: headless IPC targeted dispatch is narrowed by interactive AppCommandTargeting.
    @Test("targeted preflight keeps interactive targeting separate from headless IPC authority")
    func targetedPreflightKeepsInteractiveTargetingSeparateFromHeadlessIPCAuthority() {
        let canonicalZoomDefinition = AppCommand.zoomPane.definition
        let contextualOnlyZoomDefinition = AppCommandSpec(
            command: .zoomPane,
            label: canonicalZoomDefinition.label,
            icon: canonicalZoomDefinition.icon,
            helpText: canonicalZoomDefinition.helpText,
            surfacePolicy: canonicalZoomDefinition.surfacePolicy,
            targeting: .contextual
        )

        #expect(
            !AppCommandDispatcher.supportsTargetedDispatch(
                definition: contextualOnlyZoomDefinition,
                executionContext: .interactive,
                targetType: .pane
            ))
        #expect(
            AppCommandDispatcher.supportsTargetedDispatch(
                definition: contextualOnlyZoomDefinition,
                executionContext: .headlessIPC(admitsDebugTestingCommands: false),
                targetType: .pane
            ))
        #expect(
            !AppCommandDispatcher.supportsTargetedDispatch(
                definition: contextualOnlyZoomDefinition,
                executionContext: .headlessIPC(admitsDebugTestingCommands: false),
                targetType: .repo
            ))
    }

    // Mutation caught: contextual dispatch consults owners for a command that only declares targeted invocation.
    @Test("contextual dispatch rejects a targeted-only command before execution owners")
    func contextualDispatchRejectsTargetedOnlyCommandBeforeExecutionOwners() async throws {
        let shellOwner = RecordingDispatcherShellCommandOwner()
        let workspaceOwner = RecordingDispatcherWorkspaceCommandOwner()
        #expect(AppCommand.pinRepo.definition.targeting == .targeted([.repo]))

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = shellOwner
                configuration.workspaceOwner = workspaceOwner
            },
            body: { dispatcher in
                dispatcher.dispatch(.pinRepo)

                #expect(shellOwner.interactions.isEmpty)
                #expect(workspaceOwner.interactions.isEmpty)
            }
        )
    }

    // Mutation caught: targeted dispatch consults owners for a command that only declares contextual invocation.
    @Test("targeted dispatch rejects a contextual-only command before execution owners")
    func targetedDispatchRejectsContextualOnlyCommandBeforeExecutionOwners() async throws {
        let shellOwner = RecordingDispatcherShellCommandOwner()
        let workspaceOwner = RecordingDispatcherWorkspaceCommandOwner()
        let target = UUID()
        #expect(AppCommand.toggleSidebar.definition.targeting == .contextual)

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = shellOwner
                configuration.workspaceOwner = workspaceOwner
            },
            body: { dispatcher in
                dispatcher.dispatch(.toggleSidebar, target: target, targetType: .pane)

                #expect(shellOwner.interactions.isEmpty)
                #expect(workspaceOwner.interactions.isEmpty)
            }
        )
    }

    // Mutation caught: a dual-mode command accepts any target kind instead of its declared target set.
    @Test("targeted dispatch rejects an undeclared target kind before execution owners")
    func targetedDispatchRejectsUndeclaredTargetKindBeforeExecutionOwners() async throws {
        let shellOwner = RecordingDispatcherShellCommandOwner()
        let workspaceOwner = RecordingDispatcherWorkspaceCommandOwner()
        let target = UUID()
        #expect(
            AppCommand.zoomPane.definition.targeting
                == .contextualAndTargeted([.pane], preferredInvocation: .contextual)
        )

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = shellOwner
                configuration.workspaceOwner = workspaceOwner
            },
            body: { dispatcher in
                dispatcher.dispatch(.zoomPane, target: target, targetType: .repo)

                #expect(shellOwner.interactions.isEmpty)
                #expect(workspaceOwner.interactions.isEmpty)
            }
        )
    }

    // Mutation caught: declaration preflight replaces existing runtime capability checks for a legal mode.
    @Test("declared dual-mode target still reaches execution-owner capability checks")
    func declaredDualModeTargetStillReachesExecutionOwnerCapabilityChecks() async throws {
        let shellOwner = RecordingDispatcherShellCommandOwner(capabilityResult: false)
        let workspaceOwner = RecordingDispatcherWorkspaceCommandOwner(capabilityResult: false)
        let target = UUID()
        #expect(
            AppCommand.zoomPane.definition.targeting
                == .contextualAndTargeted([.pane], preferredInvocation: .contextual)
        )

        try await withCommandDispatcherFixture(
            configure: { configuration in
                configuration.shellOwner = shellOwner
                configuration.workspaceOwner = workspaceOwner
            },
            body: { dispatcher in
                dispatcher.dispatch(.zoomPane, target: target, targetType: .pane)

                let expectedInteractions: [DispatcherOwnerInteraction] = [
                    .targetedCapability(command: .zoomPane, target: target, targetType: .pane)
                ]
                #expect(shellOwner.interactions == expectedInteractions)
                #expect(workspaceOwner.interactions == expectedInteractions)
            }
        )
    }

    // Mutation caught: targeted-only mode preflight disables the explicit pane-to-tab multi-target route.
    @Test("specialized pane-to-tab route remains available without contextual bypass")
    func specializedPaneToTabRouteRemainsAvailableWithoutContextualBypass() async throws {
        try await withAsyncTestCoreAtoms { _ in
            let shellOwner = RecordingDispatcherShellCommandOwner(capabilityResult: false)
            let workspaceOwner = RecordingDispatcherWorkspaceCommandOwner(capabilityResult: true)
            let sourcePaneId = UUID()
            let sourceTabId = UUID()
            let targetTabId = UUID()
            #expect(AppCommand.movePaneToTab.definition.targeting == .targeted([.pane, .tab]))

            try await withCommandDispatcherFixture(
                configure: { configuration in
                    configuration.shellOwner = shellOwner
                    configuration.workspaceOwner = workspaceOwner
                },
                body: { dispatcher in
                    atom(\.managementLayer).activate()

                    #expect(!dispatcher.canDispatch(.movePaneToTab))
                    #expect(shellOwner.interactions.isEmpty)
                    #expect(workspaceOwner.interactions.isEmpty)

                    dispatcher.dispatchMovePaneToTab(
                        sourcePaneId: sourcePaneId,
                        sourceTabId: sourceTabId,
                        targetTabId: targetTabId
                    )

                    #expect(
                        shellOwner.interactions == [
                            .targetedCapability(
                                command: .movePaneToTab,
                                target: sourcePaneId,
                                targetType: .pane
                            )
                        ])
                    #expect(
                        workspaceOwner.interactions == [
                            .targetedCapability(
                                command: .movePaneToTab,
                                target: sourcePaneId,
                                targetType: .pane
                            ),
                            .specializedMovePaneExecution(
                                sourcePaneId: sourcePaneId,
                                sourceTabId: sourceTabId,
                                targetTabId: targetTabId
                            ),
                        ])
                }
            )
        }
    }
}

private final class CommandRefreshProbeClock: @unchecked Sendable {
    var nowNanoseconds: UInt64

    init(nowNanoseconds: UInt64) {
        self.nowNanoseconds = nowNanoseconds
    }

    func now() -> UInt64 { nowNanoseconds }
}

private final class CommandRefreshProbeRecorder: @unchecked Sendable {
    private(set) var records: [(AgentStudioInteractionKind, Duration)] = []

    func record(kind: AgentStudioInteractionKind, duration: Duration) {
        records.append((kind, duration))
    }
}

enum DispatcherOwnerInteraction: Equatable {
    case contextualCapability(command: AppCommand)
    case targetedCapability(command: AppCommand, target: UUID, targetType: SearchItemType)
    case contextualExecution(command: AppCommand)
    case targetedExecution(command: AppCommand, target: UUID, targetType: SearchItemType)
    case specializedMovePaneExecution(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID)
}

@MainActor
final class RecordingDispatcherShellCommandOwner: ShellCommandHandling {
    private let capabilityResult: Bool
    private let executionResult: Bool
    private(set) var interactions: [DispatcherOwnerInteraction] = []

    init(
        capabilityResult: Bool = true,
        executionResult: Bool = false
    ) {
        self.capabilityResult = capabilityResult
        self.executionResult = executionResult
    }

    func canExecute(_ command: AppCommand) -> Bool {
        interactions.append(.contextualCapability(command: command))
        return capabilityResult
    }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        interactions.append(.targetedCapability(command: command, target: target, targetType: targetType))
        return capabilityResult
    }

    func execute(_ command: AppCommand) -> Bool {
        interactions.append(.contextualExecution(command: command))
        return executionResult
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        interactions.append(.targetedExecution(command: command, target: target, targetType: targetType))
        return executionResult
    }

    func showRepoCommandBar() {}

    func refreshWorktrees() {}

    func refocusActivePane() {}
}

@MainActor
final class RecordingDispatcherWorkspaceCommandOwner: WorkspaceCommandHandling {

    private let capabilityResult: Bool
    private(set) var interactions: [DispatcherOwnerInteraction] = []

    init(capabilityResult: Bool = true) {
        self.capabilityResult = capabilityResult
    }

    func canExecute(_ command: AppCommand) -> Bool {
        interactions.append(.contextualCapability(command: command))
        return capabilityResult
    }

    func canExecute(_ command: AppCommand, target: UUID, targetType: SearchItemType) -> Bool {
        interactions.append(.targetedCapability(command: command, target: target, targetType: targetType))
        return capabilityResult
    }

    func execute(_ command: AppCommand) {
        interactions.append(.contextualExecution(command: command))
    }

    func execute(_ command: AppCommand, target: UUID, targetType: SearchItemType) {
        interactions.append(.targetedExecution(command: command, target: target, targetType: targetType))
    }

    func executeExtractPaneToTab(tabId _: UUID, paneId _: UUID, targetTabInsertionIndex _: Int?) {}

    func executeMovePaneToTab(sourcePaneId: UUID, sourceTabId: UUID?, targetTabId: UUID) {
        interactions.append(
            .specializedMovePaneExecution(
                sourcePaneId: sourcePaneId,
                sourceTabId: sourceTabId,
                targetTabId: targetTabId
            ))
    }
}
