import AgentStudioAppIPC
import AgentStudioCore
import AgentStudioInfrastructure
import AgentStudioProgrammaticControl
import AgentStudioTerminal
import Foundation

@MainActor
struct AgentStudioIPCRuntimeAdapter: AppIPCRuntimePort, @unchecked Sendable {
    private let workspaceStore: WorkspaceStore
    private let runtimeRegistry: RuntimeRegistry
    private let commandDispatcher: any PaneRuntimeCommandDispatching
    private let eventBus: EventBus<RuntimeEnvelope>
    private let terminalEventWaitDelay: AsyncDelay

    init(
        workspaceStore: WorkspaceStore,
        runtimeRegistry: RuntimeRegistry,
        commandDispatcher: any PaneRuntimeCommandDispatching,
        eventBus: EventBus<RuntimeEnvelope> = PaneRuntimeEventBus.shared,
        terminalEventWaitClock: (any Clock<Duration> & Sendable)? = nil
    ) {
        self.workspaceStore = workspaceStore
        self.runtimeRegistry = runtimeRegistry
        self.commandDispatcher = commandDispatcher
        self.eventBus = eventBus
        terminalEventWaitDelay = terminalEventWaitClock.map(AsyncDelay.clock) ?? .taskSleep
    }

    func terminalStatus(
        _ handle: IPCHandle,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) throws -> IPCTerminalStatusResult {
        let paneId = try resolveTerminalPaneId(handle)
        try requireOwnPane(ownPaneAssertion, paneId: paneId, method: "terminal.status")
        let runtimeSnapshot = try terminalRuntimeSnapshot(for: paneId)
        return IPCTerminalStatusResult(
            paneId: paneId,
            lifecycle: IPCRuntimeLifecycle(runtimeSnapshot.lifecycle),
            isReady: runtimeSnapshot.lifecycle == .ready,
            backend: IPCExecutionBackendKind(runtimeSnapshot.metadata.executionBackend),
            capabilities: capabilityNames(runtimeSnapshot.capabilities)
        )
    }

    func terminalSnapshot(
        _ handle: IPCHandle,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) throws -> IPCTerminalSnapshotResult {
        let paneId = try resolveTerminalPaneId(handle)
        try requireOwnPane(ownPaneAssertion, paneId: paneId, method: "terminal.snapshot")
        let runtime = try terminalRuntime(for: paneId)
        let runtimeSnapshot = runtime.snapshot()
        let terminalRuntimeFacts = (runtime as? any TerminalRuntimeSnapshotFactProviding)?
            .terminalRuntimeSnapshotFacts()
        return IPCTerminalSnapshotResult(
            paneId: paneId,
            lifecycle: IPCRuntimeLifecycle(runtimeSnapshot.lifecycle),
            backend: IPCExecutionBackendKind(runtimeSnapshot.metadata.executionBackend),
            capabilities: capabilityNames(runtimeSnapshot.capabilities),
            lastSequence: runtimeSnapshot.lastSeq,
            timestamp: runtimeSnapshot.timestamp,
            rendererHealthy: terminalRuntimeFacts?.rendererHealthy,
            readOnly: terminalRuntimeFacts?.readOnly,
            secureInput: terminalRuntimeFacts?.secureInput
        )
    }

    func sendTerminalInput(
        to handle: IPCHandle,
        input: String,
        correlationId: UUID?,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalSendInputResult {
        let paneId = try resolveTerminalPaneId(handle)
        _ = try terminalRuntime(for: paneId)
        // Checked in the same main-actor step that hands the input to the
        // runtime: a pane that left the agent's own pane since authorization
        // receives nothing.
        try requireOwnPane(ownPaneAssertion, paneId: paneId, method: "terminal.send")

        let result = await commandDispatcher.dispatchRuntimeCommand(
            .terminal(.sendInput(input)),
            target: .pane(PaneId(existingUUID: paneId)),
            correlationId: correlationId
        )
        return try mapTerminalSendResult(result, paneId: paneId, correlationId: correlationId)
    }

    func waitForTerminal(
        _ handle: IPCHandle,
        condition: IPCTerminalWaitCondition,
        timeout: Duration,
        afterSequence: UInt64? = nil,
        ownPaneAssertion: AppIPCOwnPaneAssertion?
    ) async throws -> IPCTerminalWaitResult {
        let paneId = try resolveTerminalPaneId(handle)
        try requireOwnPane(ownPaneAssertion, paneId: paneId, method: "terminal.wait")
        let result = try await waitForTerminalResult(
            paneId: paneId, condition: condition, timeout: timeout, afterSequence: afterSequence)
        // A wait spans later events; a pane that left the own pane while the
        // agent waited yields nothing.
        try requireOwnPane(ownPaneAssertion, paneId: paneId, method: "terminal.wait")
        return result
    }

    private func waitForTerminalResult(
        paneId: UUID,
        condition: IPCTerminalWaitCondition,
        timeout: Duration,
        afterSequence: UInt64?
    ) async throws -> IPCTerminalWaitResult {
        let runtime = try terminalRuntime(for: paneId)
        if condition == .attachReady {
            return try await waitForAttachReady(runtime: runtime, paneId: paneId, timeout: timeout)
        }

        let stream = runtime.subscribe()

        if let replayResult = try await replayedTerminalWaitResult(
            runtime: runtime,
            paneId: paneId,
            condition: condition,
            afterSequence: afterSequence
        ) {
            return replayResult
        }

        guard
            let result = await waitForTerminalEvent(
                stream: stream,
                timeout: timeout,
                { envelope in
                    Self.terminalWaitResult(
                        from: envelope,
                        paneId: paneId,
                        condition: condition,
                        afterSequence: afterSequence
                    )
                })
        else {
            throw AppIPCRuntimeError(reason: .timeout)
        }
        return result
    }

    private func replayedTerminalWaitResult(
        runtime: any PaneRuntime,
        paneId: UUID,
        condition: IPCTerminalWaitCondition,
        afterSequence: UInt64?
    ) async throws -> IPCTerminalWaitResult? {
        guard let afterSequence else { return nil }
        let replay = await runtime.eventsSince(seq: afterSequence)
        guard !replay.gapDetected else {
            throw AppIPCRuntimeError(reason: .replayGap)
        }
        return replay.events.compactMap { envelope in
            Self.terminalWaitResult(
                from: envelope,
                paneId: paneId,
                condition: condition,
                afterSequence: afterSequence
            )
        }.first
    }

    private func waitForTerminalEvent(
        stream: AsyncStream<RuntimeEnvelope>,
        timeout: Duration,
        _ extract: @Sendable @escaping (RuntimeEnvelope) -> IPCTerminalWaitResult?
    ) async -> IPCTerminalWaitResult? {
        let timeoutDelay = terminalEventWaitDelay
        return await withTaskGroup(of: IPCTerminalWaitResult?.self) { group in
            group.addTask {
                for await envelope in stream {
                    if let result = extract(envelope) {
                        return result
                    }
                }
                return nil
            }

            group.addTask {
                try? await timeoutDelay.wait(timeout)
                return nil
            }

            let first: IPCTerminalWaitResult? = if let wrapped = await group.next() { wrapped } else { nil }
            group.cancelAll()
            while await group.next() != nil {}
            return first
        }
    }

    private func waitForAttachReady(
        runtime: any PaneRuntime,
        paneId: UUID,
        timeout: Duration
    ) async throws -> IPCTerminalWaitResult {
        let start = ContinuousClock.now
        while true {
            if runtime.lifecycle == .ready {
                return IPCTerminalWaitResult(
                    paneId: paneId,
                    condition: .attachReady,
                    eventName: .terminalAttachReady,
                    commandId: nil,
                    correlationId: nil,
                    exitCode: nil,
                    duration: nil,
                    healthy: nil
                )
            }
            guard start.duration(to: ContinuousClock.now) <= timeout else {
                throw AppIPCRuntimeError(reason: .timeout)
            }
            do {
                try await Task.sleep(nanoseconds: Duration.milliseconds(100).nanosecondsForTaskSleep)
            } catch {
                // A cancelled poll must not spin back through this loop: with
                // no wait remaining, that would busy-loop the executor until
                // the real-clock guard above finally elapses. Resolve it the
                // same way a real timeout does.
                throw AppIPCRuntimeError(reason: .timeout)
            }
        }
    }

    /// Re-checks a pane agent's own pane in the same main-actor step as the
    /// read or handoff it guards.
    private func requireOwnPane(_ assertion: AppIPCOwnPaneAssertion?, paneId: UUID, method: String) throws {
        guard let assertion else { return }
        guard
            workspaceStore.ownPaneAssertionHolds(
                WorkspaceOwnPaneAssertion(boundPaneId: assertion.boundPaneId), for: paneId)
        else {
            throw AuthorizationError.notYetAllowed(method)
        }
    }

    private func terminalRuntimeSnapshot(for paneId: UUID) throws -> PaneRuntimeSnapshot {
        try terminalRuntime(for: paneId).snapshot()
    }

    private func terminalRuntime(for paneId: UUID) throws -> any PaneRuntime {
        guard let runtime = runtimeRegistry.runtime(for: PaneId(existingUUID: paneId)) else {
            throw AppIPCRuntimeError(reason: .noRuntime)
        }
        guard runtime.metadata.contentType == .terminal else {
            throw AppIPCRuntimeError(reason: .unsupportedCommand)
        }
        return runtime
    }

    private func resolveTerminalPaneId(_ handle: IPCHandle) throws -> UUID {
        guard handle.kind == .pane else {
            throw AppIPCRuntimeError(reason: .validationRejected)
        }

        let snapshot = workspaceStore.programmaticControlSnapshot()
        let pane: ProgrammaticControlPaneSnapshot?
        switch handle.reference {
        case .canonicalUUID(let paneId):
            pane = snapshot.panes.first { $0.id == paneId }
        case .friendlyOrdinal(let ordinal):
            pane = snapshot.panes[safe: ordinal - 1]
        }

        guard let pane else {
            throw AppIPCRuntimeError(reason: .targetNotFound)
        }
        guard pane.contentKind == .terminal else {
            throw AppIPCRuntimeError(reason: .unsupportedCommand)
        }
        return pane.id
    }

    private func mapTerminalSendResult(
        _ result: ActionResult,
        paneId: UUID,
        correlationId: UUID?
    ) throws -> IPCTerminalSendInputResult {
        switch result {
        case .success(let commandId):
            return IPCTerminalSendInputResult(
                paneId: paneId,
                commandId: commandId,
                correlationId: correlationId,
                disposition: .accepted,
                queuePosition: nil
            )
        case .queued(let commandId, let position):
            return IPCTerminalSendInputResult(
                paneId: paneId,
                commandId: commandId,
                correlationId: correlationId,
                disposition: .queued,
                queuePosition: position
            )
        case .failure(let error):
            throw AppIPCRuntimeError(error)
        }
    }

    private func capabilityNames(_ capabilities: Set<PaneCapability>) -> [String] {
        capabilities.map { capability in
            switch capability {
            case .input:
                return "input"
            case .resize:
                return "resize"
            case .search:
                return "search"
            case .navigation:
                return "navigation"
            case .diffReview:
                return "diffReview"
            case .editorActions:
                return "editorActions"
            case .plugin(let name):
                return "plugin:\(name)"
            }
        }
        .sorted()
    }

    private nonisolated static func terminalWaitResult(
        from envelope: RuntimeEnvelope,
        paneId: UUID,
        condition: IPCTerminalWaitCondition,
        afterSequence: UInt64? = nil
    ) -> IPCTerminalWaitResult? {
        guard case .pane(let paneEnvelope) = envelope,
            paneEnvelope.paneId.uuid == paneId,
            paneEnvelope.paneKind == .terminal,
            case .terminal(let event) = paneEnvelope.event
        else {
            return nil
        }
        if let afterSequence, paneEnvelope.seq <= afterSequence {
            return nil
        }

        switch (condition, event) {
        case (.commandFinished, .commandFinished(let exitCode, let duration)):
            return waitResult(
                paneEnvelope,
                condition: condition,
                eventName: .terminalCommandFinished,
                exitCode: exitCode,
                duration: duration
            )
        case (.rendererHealthy, .rendererHealthChanged(let healthy)) where healthy:
            return waitResult(paneEnvelope, condition: condition, eventName: .terminalRendererHealthy, healthy: healthy)
        case (.titleChanged, .titleChanged), (.titleChanged, .tabTitleChanged):
            return waitResult(paneEnvelope, condition: condition, eventName: .terminalTitleChanged)
        case (.cwdChanged, .cwdChanged):
            return waitResult(paneEnvelope, condition: condition, eventName: .terminalCwdChanged)
        case (.progressChanged, .progressReportUpdated):
            return waitResult(paneEnvelope, condition: condition, eventName: .terminalProgressChanged)
        case (.attachReady, _):
            return nil
        default:
            return nil
        }
    }

    private nonisolated static func waitResult(
        _ paneEnvelope: PaneEnvelope,
        condition: IPCTerminalWaitCondition,
        eventName: IPCEventName,
        exitCode: Int? = nil,
        duration: UInt64? = nil,
        healthy: Bool? = nil
    ) -> IPCTerminalWaitResult {
        IPCTerminalWaitResult(
            paneId: paneEnvelope.paneId.uuid,
            condition: condition,
            eventName: eventName,
            commandId: paneEnvelope.commandId,
            correlationId: paneEnvelope.correlationId,
            exitCode: exitCode,
            duration: duration,
            healthy: healthy
        )
    }
}

extension AppIPCRuntimeError {
    fileprivate init(_ actionError: ActionError) {
        switch actionError {
        case .runtimeNotReady(let lifecycle):
            self.init(reason: .runtimeNotReady, detail: String(describing: lifecycle))
        case .unsupportedCommand(let command, let required):
            self.init(reason: .unsupportedCommand, detail: "\(command) requires \(required)")
        case .invalidPayload(let description):
            self.init(reason: .validationRejected, detail: description)
        case .backendUnavailable(let backend):
            self.init(reason: .backendUnavailable, detail: backend)
        case .timeout(let commandId):
            self.init(reason: .timeout, detail: commandId.uuidString)
        }
    }
}

extension IPCRuntimeLifecycle {
    fileprivate init(_ lifecycle: PaneRuntimeLifecycle) {
        switch lifecycle {
        case .created:
            self = .created
        case .ready:
            self = .ready
        case .draining:
            self = .draining
        case .terminated:
            self = .terminated
        }
    }
}

extension IPCExecutionBackendKind {
    fileprivate init(_ backend: ExecutionBackend) {
        switch backend {
        case .local:
            self = .local
        case .docker:
            self = .docker
        case .gondolin:
            self = .gondolin
        case .remote:
            self = .remote
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
