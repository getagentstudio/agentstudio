import AgentStudioCore
import Foundation

@MainActor
protocol PaneRuntimeCommandDispatching: Sendable {
    func dispatchRuntimeCommand(
        _ command: PaneRuntimeCommand,
        target: RuntimeCommandTarget,
        correlationId: UUID?
    ) async -> ActionResult
}

@MainActor
extension WorkspaceSurfaceCoordinator {
    func dispatchRuntimeCommand(
        _ command: PaneRuntimeCommand,
        target: RuntimeCommandTarget,
        correlationId: UUID? = nil
    ) async -> ActionResult {
        guard let paneId = runtimeTargetResolver.resolve(target) else {
            Self.logger.warning(
                "Runtime command dispatch failed: unable to resolve target \(String(describing: target), privacy: .public)"
            )
            return .failure(.invalidPayload(description: "Unable to resolve pane target"))
        }

        guard let runtime = runtimeRegistry.runtime(for: paneId) else {
            Self.logger.warning(
                "Runtime command dispatch failed: no runtime registered for pane \(paneId.uuid.uuidString, privacy: .public)"
            )
            return .failure(.backendUnavailable(backend: "RuntimeRegistry"))
        }

        guard runtime.lifecycle == .ready else {
            Self.logger.warning(
                "Runtime command dispatch failed: runtime for pane \(paneId.uuid.uuidString, privacy: .public) is \(String(describing: runtime.lifecycle), privacy: .public)"
            )
            return .failure(.runtimeNotReady(lifecycle: runtime.lifecycle))
        }

        if case .diff(let diffCommand) = command,
            case .loadDiff(let artifact) = diffCommand
        {
            guard runtime.metadata.facets.worktreeId == artifact.worktreeId else {
                Self.logger.warning(
                    "Runtime command dispatch failed: diff artifact worktree mismatch pane=\(paneId.uuid.uuidString, privacy: .public) expected=\(runtime.metadata.facets.worktreeId?.uuidString ?? "nil", privacy: .public) got=\(artifact.worktreeId.uuidString, privacy: .public)"
                )
                return .failure(
                    .invalidPayload(
                        description: "Diff artifact worktree does not match runtime worktree context"
                    )
                )
            }
        }

        let envelope = RuntimeCommandEnvelope(
            commandId: UUID(),
            correlationId: correlationId,
            targetPaneId: paneId,
            command: command,
            timestamp: runtimeCommandClock.now
        )
        let result = await runtime.handleCommand(envelope)
        if case .failure(let error) = result {
            Self.logger.warning(
                "Runtime command execution failed for pane \(paneId.uuid.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        return result
    }
}
